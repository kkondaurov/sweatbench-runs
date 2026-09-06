defmodule GroupStay.ReservationsPersistenceTest do
  use ExUnit.Case, async: false
  alias GroupStay.{Repo, Reservations}

  @migrations [
    {20_260_905_000_000, GroupStay.Repo.Migrations.CreateGroups},
    {20_260_905_000_001, GroupStay.Repo.Migrations.AddCancellationEconomics}
  ]

  setup_all do
    unless Code.ensure_loaded?(GroupStay.Repo.Migrations.CreateGroups) do
      Code.require_file("priv/repo/migrations/20260905000000_create_groups.exs")
    end

    unless Code.ensure_loaded?(GroupStay.Repo.Migrations.AddCancellationEconomics) do
      Code.require_file("priv/repo/migrations/20260905000001_add_cancellation_economics.exs")
    end

    :ok
  end

  setup context do
    directory = Path.expand("tmp/reservations-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    options = [
      name: nil,
      database: Path.join(directory, "reservations.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: 10_000
    ]

    # Initialize SQLite with one connection before exercising a real connection pool.
    pid = start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    previous = Repo.put_dynamic_repo(pid)
    on_exit(fn -> Repo.put_dynamic_repo(previous) end)
    migrations = if context[:legacy], do: Enum.take(@migrations, 1), else: @migrations
    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)
    stop_supervised!(Repo)
    pid = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(pid)
    %{repo: pid, options: options}
  end

  defp opening do
    %{
      "operation_id" => "open",
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => "group",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 100}]
    }
  end

  defp payment(fields \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-02",
        "group_id" => "group",
        "amount_cents" => 50
      },
      fields
    )
  end

  defp concurrent(repo, operation) do
    1..8
    |> Task.async_stream(
      fn id ->
        Repo.put_dynamic_repo(repo)
        [result] = Reservations.submit([Map.put(operation, "operation_id", "op-#{id}")])
        result
      end,
      max_concurrency: 8,
      timeout: 15_000
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  test "migrations are repeatable and reservation accounting survives repository restart", %{
    options: options
  } do
    assert [%{status: "applied"}, %{status: "applied"}] =
             Reservations.submit([opening(), payment()])

    assert [%{status: "rejected"}, %{status: "applied"}] =
             Reservations.submit([
               payment(),
               %{
                 "operation_id" => "cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-26",
                 "group_id" => "group"
               }
             ])

    group = Reservations.get_group("group")
    ledger = Reservations.ledger()

    assert ledger == %{
             cash_held_cents: 0,
             cash_refunded_cents: 50,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }

    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)
    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == []
    assert Reservations.get_group("group") == group
    assert Reservations.ledger() == ledger
  end

  test "concurrent operations can consume a revision only once", %{repo: repo} do
    Reservations.submit([opening()])
    results = concurrent(repo, payment(%{"amount_cents" => 1, "expected_revision" => 1}))
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 7
    assert Reservations.get_group("group").revision == 2
    assert Reservations.ledger().cash_held_cents == 1
  end

  test "concurrent unconditional payments cannot overfund a deposit", %{repo: repo} do
    Reservations.submit([opening()])
    results = concurrent(repo, payment())
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "payment_exceeds_outstanding")) == 7
    assert Reservations.get_group("group").outstanding_deposit_cents == 10
    assert Reservations.ledger().cash_held_cents == 50
  end

  test "concurrent duplicate openings create exactly one group", %{repo: repo} do
    results = concurrent(repo, opening())
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_already_exists")) == 7
    assert Reservations.get_group("group").revision == 1
  end

  test "concurrent cancellations settle cash only once", %{repo: repo} do
    Reservations.submit([opening(), payment()])

    results =
      concurrent(repo, %{
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group"
      })

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_not_active")) == 7
    assert Reservations.get_group("group").revision == 3

    assert Reservations.ledger() == %{
             cash_held_cents: 0,
             cash_refunded_cents: 50,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }
  end

  @tag :legacy
  test "upgrade backfills original booking policies and preserves existing balances", %{
    options: options
  } do
    cases = [
      {"old", "2026-12-31", "flexible", "active", 50, 0, "flex-14", ~D[2027-02-15]},
      {"new", "2027-01-01", "flexible", "active", 40, 0, "flex-30", ~D[2027-01-30]},
      {"advance", "2026-12-31", "advance_purchase", "active", 30, 0, "advance-nonrefundable",
       nil},
      {"cancelled", "2027-01-01", "flexible", "cancelled", 0, 20, "flex-30", ~D[2027-01-30]}
    ]

    for {id, booked, plan, status, paid, refunded, _, _} <- cases do
      Repo.query!(
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on,
          departure_on, rate_plan, status, revision, rooms, lodging_total_cents,
          deposit_due_cents, deposit_paid_cents, cash_refunded_cents, cash_retained_cents)
        VALUES (?, 'guest', 'hotel', ?, '2027-03-01', '2027-03-04', ?, ?, 7, ?, 300, ?, ?, ?, 0)
        """,
        [
          id,
          booked,
          plan,
          status,
          Jason.encode!(opening()["rooms"]),
          if(status == "active", do: 60, else: 0),
          paid,
          refunded
        ]
      )
    end

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_905_000_001
           ]

    for {id, _, _, status, paid, _, policy, deadline} <- cases do
      group = Reservations.get_group(id)
      assert group.policy_version == policy
      assert group.refundable_until == deadline
      assert group.cash_paid_cents == paid
      assert group.deposit_paid_cents == paid
      assert group.credit_paid_cents == 0
      assert group.revision == 7
      assert group.status == status
    end

    assert Reservations.ledger().cash_held_cents == 120
    assert Reservations.ledger().cash_refunded_cents == 20

    stop_supervised!(Repo)
    Repo.put_dynamic_repo(start_supervised!({Repo, options}))
    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == []

    for {id, refunded, retained} <- [{"old", 50, 0}, {"new", 0, 40}, {"advance", 0, 30}] do
      assert [%{revision: 8, refunded_cents: ^refunded, retained_cents: ^retained}] =
               Reservations.submit([
                 %{
                   "operation_id" => "cancel-#{id}",
                   "type" => "cancel_group",
                   "group_id" => id,
                   "occurred_on" => "2027-02-15",
                   "expected_revision" => 7
                 }
               ])
    end
  end

  defp funded_credit do
    assert [%{status: "applied"}, %{status: "applied"}, %{credit_issued_cents: 55}] =
             Reservations.submit([
               opening(),
               payment(),
               %{
                 "operation_id" => "source",
                 "type" => "cancel_group",
                 "group_id" => "group",
                 "occurred_on" => "2026-11-26",
                 "refund_method" => "hotel_credit"
               }
             ])
  end

  defp credit_payment(group_id, amount, fields \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "credit-#{group_id}",
        "type" => "apply_hotel_credit",
        "group_id" => group_id,
        "amount_cents" => amount,
        "occurred_on" => "2026-11-26"
      },
      fields
    )
  end

  test "credit lots, funding provenance and paused expiry survive repository restart", %{
    options: options
  } do
    funded_credit()

    Reservations.submit([
      Map.merge(opening(), %{
        "group_id" => "target",
        "arrival_on" => "2028-01-01",
        "departure_on" => "2028-01-04"
      }),
      credit_payment("target", 40)
    ])

    group = Reservations.get_group("target")
    assert group.credit_paid_cents == 40
    assert Reservations.guest_credit("guest", ~D[2027-11-26]).available_cents == 15
    assert Reservations.ledger(~D[2027-11-27]).credit_liability_cents == 40

    stop_supervised!(Repo)
    Repo.put_dynamic_repo(start_supervised!({Repo, options}))
    assert Reservations.get_group("target") == group
    assert Reservations.guest_credit("guest", ~D[2027-11-26]).available_cents == 15
    assert Reservations.ledger(~D[2027-11-27]).credit_liability_cents == 40

    assert [%{revision: 3, refunded_cents: 0, retained_cents: 0, credit_issued_cents: 0}] =
             Reservations.submit([
               %{
                 "operation_id" => "cancel-target",
                 "type" => "cancel_group",
                 "group_id" => "target",
                 "occurred_on" => "2027-11-27"
               }
             ])

    assert Reservations.guest_credit("guest", ~D[2027-11-27]).available_cents == 0
    assert Reservations.ledger(~D[2027-11-27]).credit_liability_cents == 0
    assert Reservations.ledger().cash_converted_to_credit_cents == 50
  end

  test "concurrent groups cannot spend the same guest credit twice", %{repo: repo} do
    funded_credit()
    for id <- 1..8, do: Reservations.submit([Map.put(opening(), "group_id", "target-#{id}")])

    results =
      1..8
      |> Task.async_stream(
        fn id ->
          Repo.put_dynamic_repo(repo)
          [result] = Reservations.submit([credit_payment("target-#{id}", 40)])
          result
        end,
        max_concurrency: 8,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "insufficient_credit")) == 7
    assert Reservations.guest_credit("guest", ~D[2026-11-26]).available_cents == 15
    assert Reservations.ledger(~D[2026-11-26]).credit_liability_cents == 55
  end

  test "concurrent credit applications consume a revision only once", %{repo: repo} do
    funded_credit()
    Reservations.submit([Map.put(opening(), "group_id", "target")])
    results = concurrent(repo, credit_payment("target", 1, %{"expected_revision" => 1}))
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 7
    assert Reservations.get_group("target").revision == 2
    assert Reservations.guest_credit("guest", ~D[2026-11-26]).available_cents == 54
  end

  test "concurrent cancellations issue one credit lot", %{repo: repo} do
    Reservations.submit([opening(), payment()])

    results =
      concurrent(repo, %{
        "type" => "cancel_group",
        "group_id" => "group",
        "occurred_on" => "2026-11-26",
        "refund_method" => "hotel_credit"
      })

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_not_active")) == 7
    assert [%{remaining_cents: 55}] = Reservations.guest_credit("guest", ~D[2026-11-26]).lots
    assert Reservations.ledger(~D[2026-11-26]).cash_converted_to_credit_cents == 50
    assert Reservations.get_group("group").revision == 3
  end
end
