defmodule GroupStay.PersistenceTest do
  use ExUnit.Case, async: false

  alias GroupStay.{Repo, Reservations}

  @migrations [
    {20_260_905_000_000, GroupStay.Repo.Migrations.CreateGroups},
    {20_260_905_000_001, GroupStay.Repo.Migrations.AddCancellationEconomics},
    {20_260_905_000_002, GroupStay.Repo.Migrations.CreateOperations}
  ]

  setup_all do
    for {version, module} <- @migrations do
      unless Code.ensure_loaded?(module) do
        [path] =
          Path.wildcard(Application.app_dir(:group_stay, "priv/repo/migrations/#{version}_*.exs"))

        Code.require_file(path)
      end
    end

    :ok
  end

  defp migrate(options \\ []) do
    Ecto.Migrator.run(
      Repo,
      @migrations,
      :up,
      Keyword.merge([all: not Keyword.has_key?(options, :to), log: false], options)
    )
  end

  setup context do
    File.mkdir_p!("tmp")
    database = Path.expand("tmp/persistence-#{System.unique_integer([:positive])}.db")

    options = [
      name: nil,
      database: database,
      pool: DBConnection.ConnectionPool,
      pool_size: 4
    ]

    # Initialize SQLite's WAL with one connection before opening a concurrent pool.
    initial = start_supervised!({Repo, Keyword.put(options, :pool_size, 1)}, id: :isolated_repo)
    Repo.put_dynamic_repo(initial)
    Repo.query!("SELECT 1")
    :ok = stop_supervised(:isolated_repo)
    pid = start_supervised!({Repo, options}, id: :isolated_repo)
    Repo.put_dynamic_repo(pid)

    if context[:legacy], do: migrate(to: 20_260_905_000_000), else: migrate()

    on_exit(fn ->
      for path <- [database, database <> "-wal", database <> "-shm"] do
        assert File.rm(path) in [:ok, {:error, :enoent}]
      end
    end)

    %{repo: pid, options: options}
  end

  defp opening do
    %{
      "operation_id" => "open",
      "type" => "open_group",
      "occurred_on" => "2026-09-01",
      "group_id" => "g",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 1000}]
    }
  end

  defp payment(id, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => "record_cash_payment",
        "group_id" => "g",
        "occurred_on" => "2026-09-01",
        "amount_cents" => 150
      },
      extra
    )
  end

  defp race(repo, operations) do
    parent = self()

    tasks =
      Enum.map(operations, fn op ->
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          send(parent, {:ready, self()})

          receive do
            :go -> hd(Reservations.batch([op]))
          end
        end)
      end)

    for %{pid: pid} <- tasks do
      assert_receive {:ready, ^pid}
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 15_000))
  end

  test "concurrent revision checks allow exactly one payment", %{repo: repo} do
    Reservations.batch([opening()])

    results =
      race(repo, [
        payment("one", %{"expected_revision" => 1}),
        payment("two", %{"expected_revision" => 1})
      ])

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(&1[:code] == "stale_revision" and &1.actual_revision == 2)) == 1
    assert Reservations.get_group("g").revision == 2
    assert Reservations.ledger().cash_held_cents == 150
  end

  test "concurrent unconditional payments cannot overfund", %{repo: repo} do
    Reservations.batch([opening()])
    results = race(repo, [payment("one"), payment("two")])
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(&1[:code] == "payment_exceeds_outstanding")) == 1
    assert Reservations.get_group("g").outstanding_deposit_cents == 50
  end

  test "concurrent opens preserve unique group identifiers", %{repo: repo} do
    results = race(repo, [opening(), %{opening() | "operation_id" => "other"}])
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(&1[:code] == "group_already_exists")) == 1
    assert Reservations.get_group("g").revision == 1
  end

  test "groups and settlements survive repository restart and migration rerun", %{
    options: options
  } do
    Reservations.batch([
      opening(),
      payment("cash"),
      %{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "group_id" => "g",
        "occurred_on" => "2026-12-01"
      }
    ])

    group = Reservations.get_group("g")
    ledger = Reservations.ledger()
    :ok = stop_supervised(:isolated_repo)
    pid = start_supervised!({Repo, options}, id: :isolated_repo)
    Repo.put_dynamic_repo(pid)

    assert migrate() == []

    assert Reservations.get_group("g") == group
    assert Reservations.ledger() == ledger

    assert ledger == %{
             cash_held_cents: 0,
             cash_refunded_cents: 0,
             cash_retained_cents: 150,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }
  end

  @tag capture_log: true
  test "concurrent exact retries and conflicting submissions have at-most-once effects", %{
    repo: repo
  } do
    results = race(repo, List.duplicate(opening(), 4))
    assert length(Enum.uniq(results)) == 1
    assert hd(results).revision == 1
    results = race(repo, List.duplicate(payment("retry"), 4))
    assert length(Enum.uniq(results)) == 1
    assert hd(results).revision == 2
    assert Reservations.ledger().cash_held_cents == 150

    results =
      race(repo, [
        payment("conflict", %{"amount_cents" => 10}),
        payment("conflict", %{"amount_cents" => 20})
      ])

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(&1[:code] == "operation_id_conflict")) == 1
    assert Reservations.get_group("g").revision == 3
    assert Repo.aggregate(GroupStay.Reservations.Operation, :count) == 3
  end

  @tag capture_log: true
  test "transient initial write-lock contention retries before applying", %{options: options} do
    :ok = stop_supervised(:isolated_repo)
    repo = start_supervised!({Repo, Keyword.put(options, :busy_timeout, 0)}, id: :isolated_repo)
    Repo.put_dynamic_repo(repo)
    Reservations.batch([opening()])
    parent = self()

    holder =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)

        Repo.transaction(
          fn ->
            send(parent, :locked)

            receive do
              :release -> :ok
            end
          end,
          mode: :immediate
        )
      end)

    assert_receive :locked
    Process.send_after(holder.pid, :release, 40)
    assert [%{revision: 2, amount_cents: 150}] = Reservations.batch([payment("retry-lock")])
    assert Task.await(holder) == {:ok, :ok}
    assert Reservations.ledger().cash_held_cents == 150
    assert Repo.aggregate(GroupStay.Reservations.Operation, :count) == 2
  end

  test "applied and rejected audit records survive reopening the database", %{options: options} do
    operations = [
      payment("missing"),
      opening(),
      payment("cash"),
      payment("stale", %{"expected_revision" => 1})
    ]

    original = Reservations.batch(operations)
    records = Repo.all(GroupStay.Reservations.Operation)
    :ok = stop_supervised(:isolated_repo)
    pid = start_supervised!({Repo, options}, id: :isolated_repo)
    Repo.put_dynamic_repo(pid)
    assert migrate() == []
    assert Reservations.batch(operations) == original
    assert Repo.all(GroupStay.Reservations.Operation) == records
    Reservations.batch([payment("after-restart", %{"amount_cents" => 500})])
    added = Repo.get_by!(GroupStay.Reservations.Operation, operation_id: "after-restart")
    assert added.id > Enum.max_by(records, & &1.id).id
    assert added.result["code"] == "payment_exceeds_outstanding"
    assert Reservations.get_group("g").revision == 2
    assert Reservations.ledger().cash_held_cents == 150

    for result <- original do
      assert Reservations.get_operation(result.operation_id) ==
               Jason.decode!(Jason.encode!(result))
    end
  end

  test "a fresh application process replays durable outcomes", %{options: options} do
    operations = [opening(), payment("cash"), payment("stale", %{"expected_revision" => 1})]
    original = Reservations.batch(operations)
    :ok = stop_supervised(:isolated_repo)

    script = """
    results = GroupStay.Reservations.batch(#{inspect(operations)})
    unless Jason.decode!(Jason.encode!(results)) == Jason.decode!(#{inspect(Jason.encode!(original))}), do: raise("retry changed")
    unless GroupStay.Reservations.get_group("g").revision == 2, do: raise("duplicate effect")
    IO.puts("durable-replay-ok")
    """

    {output, status} =
      System.cmd("mix", ["run", "--no-compile", "-e", script],
        env: [{"MIX_ENV", "test"}, {"GROUP_STAY_DATABASE_PATH", options[:database]}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "durable-replay-ok"
  end

  test "audit insert faults return 500, roll back domain writes, and abort the rest of the batch" do
    Repo.query!("""
    CREATE TRIGGER fail_audit BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    operations = [opening(), payment("fault"), payment("later", %{"amount_cents" => 10})]

    Phoenix.ConnTest.assert_error_sent(500, fn ->
      Phoenix.ConnTest.dispatch(
        Phoenix.ConnTest.build_conn(),
        GroupStayWeb.Endpoint,
        :post,
        "/api/v1/partner-batches",
        %{"operations" => operations}
      )
    end)

    assert Reservations.get_group("g").revision == 1
    assert Reservations.ledger().cash_held_cents == 0
    assert Reservations.get_operation("open")["status"] == "applied"
    assert Reservations.get_operation("fault") == nil
    assert Reservations.get_operation("later") == nil
    Repo.query!("DROP TRIGGER fail_audit")
    assert [%{revision: 1}, %{revision: 2}, %{revision: 3}] = Reservations.batch(operations)
    assert Reservations.ledger().cash_held_cents == 160
  end

  test "fault during credit cancellation rolls back lot creation and can be retried" do
    Reservations.batch([opening(), payment("cash")])

    Repo.query!("""
    CREATE TRIGGER fail_settlement BEFORE UPDATE ON groups
    WHEN NEW.status = 'cancelled'
    BEGIN SELECT RAISE(ABORT, 'injected settlement failure'); END
    """)

    cancellation = %{
      "operation_id" => "cancel",
      "type" => "cancel_group",
      "group_id" => "g",
      "occurred_on" => "2026-11-01",
      "refund_method" => "hotel_credit"
    }

    assert_raise Exqlite.Error, fn -> Reservations.batch([cancellation]) end
    assert Reservations.get_operation("cancel") == nil
    assert Reservations.get_group("g").revision == 2
    assert Reservations.ledger(~D[2026-11-01]).cash_held_cents == 150
    assert Repo.all(GroupStay.Reservations.CreditLot) == []
    Repo.query!("DROP TRIGGER fail_settlement")
    assert [%{credit_issued_cents: 165, revision: 3}] = Reservations.batch([cancellation])
    assert Repo.aggregate(GroupStay.Reservations.CreditLot, :count) == 1
  end

  @tag :legacy
  test "upgrades original rows without changing their deposits, revisions or settlements" do
    for {id, plan, booked, status, paid, refunded, retained} <- [
          {"old", "flexible", "2026-12-31", "active", 150, 0, 0},
          {"new", "flexible", "2027-01-01", "active", 100, 0, 0},
          {"advance", "advance_purchase", "2026-12-31", "active", 200, 0, 0},
          {"cancelled", "flexible", "2026-12-31", "cancelled", 0, 150, 0}
        ] do
      Repo.query!(
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, status, revision, rooms, lodging_total_cents, deposit_due_cents,
          deposit_paid_cents, refunded_cents, retained_cents)
        VALUES (?, 'guest', 'hotel', ?, '2027-06-01', '2027-06-02', ?, ?, 3,
          '[{"room_id":"r","nightly_rate_cents":1000}]', 1000, ?, ?, ?, ?)
        """,
        [
          id,
          booked,
          plan,
          status,
          if(status == "active", do: 200, else: 0),
          paid,
          refunded,
          retained
        ]
      )
    end

    assert migrate() == [20_260_905_000_001, 20_260_905_000_002]
    assert migrate() == []
    assert Repo.all(GroupStay.Reservations.Operation) == []
    assert Reservations.get_group("old").policy_version == "flex-14"
    assert Reservations.get_group("new").policy_version == "flex-30"
    assert Reservations.get_group("advance").refundable_until == nil
    assert Reservations.get_group("cancelled").status == "cancelled"
    assert Reservations.get_group("old").revision == 3
    assert Reservations.get_group("old").cash_paid_cents == 150
    assert Reservations.ledger().cash_held_cents == 450
    assert Reservations.ledger().cash_refunded_cents == 150

    assert [%{refunded_cents: 150, revision: 4}] =
             Reservations.batch([
               %{
                 "type" => "cancel_group",
                 "group_id" => "old",
                 "operation_id" => "refund",
                 "occurred_on" => "2027-05-18"
               }
             ])
  end

  defp credit_source do
    Reservations.batch([
      opening(),
      payment("cash"),
      %{
        "operation_id" => "credit-source",
        "type" => "cancel_group",
        "group_id" => "g",
        "occurred_on" => "2026-11-01",
        "refund_method" => "hotel_credit"
      }
    ])
  end

  defp redemption(id, amount) do
    %{
      "type" => "apply_hotel_credit",
      "operation_id" => "redeem-#{id}",
      "group_id" => id,
      "occurred_on" => "2026-11-02",
      "amount_cents" => amount,
      "expected_revision" => 1
    }
  end

  test "concurrent groups cannot spend the same guest credit", %{repo: repo} do
    credit_source()

    Reservations.batch([
      %{opening() | "group_id" => "one", "operation_id" => "open-one"},
      %{opening() | "group_id" => "two", "operation_id" => "open-two"}
    ])

    results = race(repo, [redemption("one", 150), redemption("two", 150)])
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(&1[:code] == "insufficient_credit")) == 1
    assert Reservations.guest_credit("guest", ~D[2026-11-02]).available_cents == 15
    assert Reservations.ledger(~D[2026-11-02]).credit_liability_cents == 165
  end

  test "credit lots and their funding provenance survive restart", %{options: options} do
    credit_source()

    Reservations.batch([
      %{opening() | "group_id" => "target", "operation_id" => "open-target"},
      redemption("target", 100)
    ])

    :ok = stop_supervised(:isolated_repo)
    pid = start_supervised!({Repo, options}, id: :isolated_repo)
    Repo.put_dynamic_repo(pid)
    assert migrate() == []
    assert Reservations.get_group("target").credit_paid_cents == 100
    assert Reservations.guest_credit("guest", ~D[2026-11-02]).available_cents == 65

    assert [%{credit_issued_cents: 0, revision: 3}] =
             Reservations.batch([
               %{
                 "operation_id" => "restore",
                 "type" => "cancel_group",
                 "group_id" => "target",
                 "occurred_on" => "2026-11-02"
               }
             ])

    assert Reservations.guest_credit("guest", ~D[2026-11-02]).lots == [
             %{
               source_operation_id: "credit-source",
               remaining_cents: 165,
               expires_on: ~D[2027-11-01]
             }
           ]

    assert Reservations.ledger(~D[2026-11-02]).cash_converted_to_credit_cents == 150
  end
end
