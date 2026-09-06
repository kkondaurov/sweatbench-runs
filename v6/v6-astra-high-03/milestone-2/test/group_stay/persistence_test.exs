defmodule GroupStay.PersistenceTest do
  use ExUnit.Case, async: false

  alias GroupStay.{Repo, Reservations}

  @moduletag capture_log: true

  @migrations [
    {20_260_905_000_000, GroupStay.Repo.Migrations.CreateGroups},
    {20_260_905_000_100, GroupStay.Repo.Migrations.AddCancellationEconomics}
  ]

  setup_all do
    for {version, module} <- @migrations do
      unless Code.ensure_loaded?(module) do
        [path] = Path.wildcard("priv/repo/migrations/#{version}_*.exs")
        Code.require_file(path)
      end
    end

    :ok
  end

  defp migrate do
    Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)
  end

  setup do
    directory = Path.expand("tmp/persistence-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> remove_database_directory(directory) end)

    options = [
      name: nil,
      database: Path.join(directory, "reservations.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: 50
    ]

    # Initialize the file with one connection before opening the concurrent pool,
    # so new connections do not race to enable SQLite's WAL journal mode.
    initial_repo = start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    Repo.put_dynamic_repo(initial_repo)
    migrate()
    stop_supervised!(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    %{repo: repo, options: options}
  end

  # SQLite can finish cleaning up WAL sidecars just after its pool shuts down.
  defp remove_database_directory(directory, retries \\ 10) do
    case File.rm_rf(directory) do
      {:ok, _} ->
        :ok

      {:error, reason, _} when reason in [:eexist, :enotempty] and retries > 0 ->
        Process.sleep(10)
        remove_database_directory(directory, retries - 1)

      {:error, reason, path} ->
        raise File.Error, reason: reason, path: path, action: "remove test database"
    end
  end

  defp opening do
    %{
      "operation_id" => "open",
      "type" => "open_group",
      "occurred_on" => "2026-01-01",
      "group_id" => "persistent",
      "guest_id" => "guest",
      "property_id" => "property",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-12",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10000}]
    }
  end

  defp payment(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => "persistent",
        "amount_cents" => 2000
      },
      overrides
    )
  end

  defp concurrently(repo, op) do
    parent = self()

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          send(parent, {:ready, self()})

          receive do
            :go -> Reservations.apply_batch([op]) |> hd()
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _})
    for task <- tasks, do: send(task.pid, :go)
    Task.await_many(tasks, 30_000)
  end

  test "concurrent conditional payments have exactly one winner", %{repo: repo} do
    Reservations.apply_batch([opening()])
    results = concurrently(repo, payment(%{"expected_revision" => 1}))
    assert Enum.count(results, &(&1.status == "applied")) == 1
    rejected = Enum.filter(results, &(&1.status == "rejected"))
    assert length(rejected) == 7
    assert Enum.all?(rejected, &(&1.code == "stale_revision" and &1.actual_revision == 2))
    assert %{revision: 2, deposit_paid_cents: 2000} = Reservations.get_group("persistent")
    assert Reservations.ledger().cash_held_cents == 2000
  end

  test "concurrent unconditional payments cannot overfund a deposit", %{repo: repo} do
    Reservations.apply_batch([opening()])
    results = concurrently(repo, payment())
    assert Enum.count(results, &(&1.status == "applied")) == 2
    assert Enum.count(results, &(Map.get(&1, :code) == "payment_exceeds_outstanding")) == 6

    assert %{revision: 3, deposit_paid_cents: 4000, outstanding_deposit_cents: 0} =
             Reservations.get_group("persistent")

    assert Reservations.ledger().cash_held_cents == 4000
  end

  test "concurrent opening preserves uniqueness", %{repo: repo} do
    results = concurrently(repo, opening())
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_already_exists")) == 7
    assert Reservations.get_group("persistent").revision == 1
  end

  test "migrations are repeatable and groups and settlements survive repository restarts", %{
    options: options
  } do
    Reservations.apply_batch([opening(), payment()])
    group = Reservations.get_group("persistent")
    ledger = Reservations.ledger()

    stop_supervised!(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert migrate() == []
    assert Reservations.get_group("persistent") == group
    assert Reservations.ledger() == ledger

    assert [%{refunded_cents: 2000, revision: 3}] =
             Reservations.apply_batch([
               payment(%{"type" => "cancel_group", "expected_revision" => 2})
             ])

    stop_supervised!(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)

    assert %{status: "cancelled", revision: 3, outstanding_deposit_cents: 0} =
             Reservations.get_group("persistent")

    assert Reservations.ledger() == %{
             cash_held_cents: 0,
             cash_refunded_cents: 2000,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }
  end

  test "a busy transaction retries without applying a payment twice", %{
    repo: repo,
    options: options
  } do
    Reservations.apply_batch([opening()])
    {:ok, blocker} = Exqlite.Sqlite3.open(options[:database])
    on_exit(fn -> Exqlite.Sqlite3.close(blocker) end)
    :ok = Exqlite.Sqlite3.execute(blocker, "BEGIN IMMEDIATE TRANSACTION")

    task =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)
        Reservations.apply_batch([payment(%{"expected_revision" => 1})])
      end)

    # Hold the external writer lock beyond the connection's busy timeout.
    assert Task.yield(task, 160) == nil
    :ok = Exqlite.Sqlite3.execute(blocker, "COMMIT")
    assert [%{status: "applied", revision: 2}] = Task.await(task, 5000)
    assert %{revision: 2, deposit_paid_cents: 2000} = Reservations.get_group("persistent")
    assert Reservations.ledger().cash_held_cents == 2000
  end

  test "upgrade backfills original booking policies and preserves existing accounting" do
    Ecto.Migrator.run(Repo, @migrations, :down, step: 1, log: false)

    for {id, booked, plan, status, paid, refunded, retained} <- [
          {"old", "2026-12-31", "flexible", "active", 100, 0, 0},
          {"new", "2027-01-01", "flexible", "active", 200, 0, 0},
          {"advance", "2027-01-01", "advance_purchase", "active", 300, 0, 0},
          {"settled", "2026-01-01", "flexible", "cancelled", 0, 50, 0},
          {"retained", "2026-01-01", "advance_purchase", "cancelled", 0, 0, 70}
        ] do
      Repo.query!(
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, status, revision, rooms, lodging_total_cents, deposit_due_cents,
          deposit_paid_cents, cash_refunded_cents, cash_retained_cents)
        VALUES (?, 'guest', 'hotel', ?, '2028-06-01', '2028-06-02', ?, ?, 4,
          '[{"room_id":"room","nightly_rate_cents":10000}]', 10000, ?, ?, ?, ?)
        """,
        [
          id,
          booked,
          plan,
          status,
          if(status == "active", do: 2000, else: 0),
          paid,
          refunded,
          retained
        ]
      )
    end

    assert migrate() == [20_260_905_000_100]
    assert migrate() == []

    for {id, policy, paid, until} <- [
          {"old", "flex-14", 100, ~D[2028-05-18]},
          {"new", "flex-30", 200, ~D[2028-05-02]},
          {"advance", "advance-nonrefundable", 300, nil}
        ] do
      assert %{
               policy_version: ^policy,
               revision: 4,
               cash_paid_cents: ^paid,
               deposit_paid_cents: ^paid,
               credit_paid_cents: 0,
               refundable_until: ^until
             } = Reservations.get_group(id)
    end

    assert Reservations.get_group("settled").status == "cancelled"

    assert Reservations.ledger() == %{
             cash_held_cents: 600,
             cash_refunded_cents: 50,
             cash_retained_cents: 70,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }

    assert [%{refunded_cents: 100, revision: 5}] =
             Reservations.apply_batch([
               payment(%{
                 "type" => "cancel_group",
                 "group_id" => "old",
                 "occurred_on" => "2028-05-18",
                 "expected_revision" => 4
               })
             ])
  end

  defp create_credit do
    assert [_, _, %{credit_issued_cents: 2200}] =
             Reservations.apply_batch([
               opening(),
               payment(),
               payment(%{"type" => "cancel_group", "refund_method" => "hotel_credit"})
             ])
  end

  test "credit lots and their active allocations survive restarts and restore to the original expiry",
       %{options: options} do
    create_credit()

    Reservations.apply_batch([
      Map.put(opening(), "group_id", "target"),
      payment(%{"type" => "apply_hotel_credit", "group_id" => "target", "amount_cents" => 1500})
    ])

    before = Reservations.ledger(~D[2026-01-02])
    stop_supervised!(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert Reservations.ledger(~D[2026-01-02]) == before

    assert %{credit_paid_cents: 1500, cash_paid_cents: 0, revision: 2} =
             Reservations.get_group("target")

    assert %{available_cents: 700} = Reservations.guest_credit("guest", ~D[2026-01-02])

    assert [%{revision: 3, credit_issued_cents: 0}] =
             Reservations.apply_batch([
               payment(%{"type" => "cancel_group", "group_id" => "target"})
             ])

    stop_supervised!(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)

    assert %{
             available_cents: 2200,
             lots: [%{source_operation_id: "pay", expires_on: ~D[2027-01-02]}]
           } =
             Reservations.guest_credit("guest", ~D[2027-01-02])

    assert Reservations.ledger(~D[2027-01-03]).credit_liability_cents == 0
  end

  test "concurrent redemption across groups cannot spend the same guest credit twice", %{
    repo: repo
  } do
    create_credit()

    for index <- 1..8 do
      Reservations.apply_batch([Map.put(opening(), "group_id", "target-#{index}")])
    end

    parent = self()

    tasks =
      for index <- 1..8 do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          send(parent, {:ready, self()})

          receive do
            :go ->
              Reservations.apply_batch([
                payment(%{
                  "type" => "apply_hotel_credit",
                  "group_id" => "target-#{index}",
                  "amount_cents" => 1100
                })
              ])
              |> hd()
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _})
    for task <- tasks, do: send(task.pid, :go)
    results = Task.await_many(tasks, 30_000)
    assert Enum.count(results, &(&1.status == "applied")) == 2
    assert Enum.count(results, &(Map.get(&1, :code) == "insufficient_credit")) == 6
    assert Reservations.guest_credit("guest", ~D[2026-01-02]).available_cents == 0
    assert Reservations.ledger(~D[2028-01-01]).credit_liability_cents == 2200
  end

  test "concurrent credit cancellations create exactly one lot", %{repo: repo} do
    Reservations.apply_batch([opening(), payment()])

    results =
      concurrently(
        repo,
        payment(%{
          "type" => "cancel_group",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        })
      )

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 7

    assert %{available_cents: 2200, lots: [_]} =
             Reservations.guest_credit("guest", ~D[2026-01-02])

    assert Reservations.ledger().cash_converted_to_credit_cents == 2000
  end
end
