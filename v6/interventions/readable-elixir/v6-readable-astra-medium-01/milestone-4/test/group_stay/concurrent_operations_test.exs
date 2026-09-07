defmodule GroupStay.ConcurrentOperationsTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias GroupStay.{Repo, Reservations}

  # Real connections are essential here: sandbox tasks share one transaction and
  # cannot exercise SQLite's writer locking between independent transactions.
  setup context do
    directory = Path.join(File.cwd!(), ".concurrency-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)

    options = [
      name: nil,
      database: Path.join(directory, "groups.db"),
      pool: DBConnection.ConnectionPool
    ]

    # Initialize the database before opening competing connections so their
    # connection pragmas do not race the initial journal setup.
    repo = start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})

    Repo.put_dynamic_repo(repo)

    migration_options =
      cond do
        context[:legacy] -> [to: 20_260_907_000_000]
        context[:room_upgrade] -> [to: 20_260_907_000_002]
        true -> [all: true]
      end

    Ecto.Migrator.run(
      Repo,
      Application.app_dir(:group_stay, "priv/repo/migrations"),
      :up,
      Keyword.put(migration_options, :log, false)
    )

    stop_supervised!(Repo)
    repo = start_supervised!({Repo, Keyword.put(options, :pool_size, 4)})
    Repo.put_dynamic_repo(repo)

    on_exit(fn ->
      if Process.alive?(repo), do: Supervisor.stop(repo)
      remove_database_directory(directory, 10)
    end)

    %{repo: repo, options: options}
  end

  # SQLite native handles can finish releasing WAL files after the pool exits.
  # Some filesystems briefly report a nonempty directory during that cleanup.
  defp remove_database_directory(directory, retries) do
    case File.rm_rf(directory) do
      {:ok, _} ->
        :ok

      {:error, reason, _} when reason in [:eexist, :enotempty] and retries > 0 ->
        Process.sleep(20)
        remove_database_directory(directory, retries - 1)

      {:error, reason, path} ->
        raise File.Error, reason: reason, action: "remove test database", path: path
    end
  end

  test "competing writers cannot both apply the same revision", %{repo: repo} do
    assert [%{revision: 1}] =
             Reservations.submit([
               %{
                 "operation_id" => "open",
                 "type" => "open_group",
                 "group_id" => "concurrent",
                 "guest_id" => "guest",
                 "property_id" => "hotel",
                 "occurred_on" => "2026-10-03",
                 "arrival_on" => "2026-12-10",
                 "departure_on" => "2026-12-13",
                 "rate_plan" => "flexible",
                 "rooms" => [%{"room_id" => "one", "nightly_rate_cents" => 15000}]
               }
             ])

    results =
      1..8
      |> Task.async_stream(
        fn index ->
          Repo.put_dynamic_repo(repo)

          [result] =
            Reservations.submit([
              %{
                "operation_id" => "payment-#{index}",
                "type" => "record_cash_payment",
                "occurred_on" => "2026-10-04",
                "group_id" => "concurrent",
                "amount_cents" => 100,
                "expected_revision" => 1
              }
            ])

          result
        end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 7
    assert Reservations.get_group("concurrent").revision == 2
    assert Reservations.ledger().cash_held_cents == 100
  end

  test "concurrent exact retries commit once and survive a database pool restart", %{
    repo: repo,
    options: options
  } do
    operation = %{
      "operation_id" => "retry-open",
      "type" => "open_group",
      "group_id" => "retry-group",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "occurred_on" => "2027-01-01",
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10000}]
    }

    results = concurrent_submit(repo, List.duplicate(operation, 8))

    assert Enum.uniq(results) == [
             %{
               operation_id: "retry-open",
               status: "applied",
               group_id: "retry-group",
               revision: 1,
               deposit_due_cents: 2000
             }
           ]

    payment = %{
      "operation_id" => "retry-payment",
      "type" => "record_cash_payment",
      "group_id" => "retry-group",
      "occurred_on" => "2027-01-02",
      "amount_cents" => 100
    }

    payments = concurrent_submit(repo, List.duplicate(payment, 8))
    assert length(Enum.uniq(payments)) == 1
    assert hd(payments).revision == 2
    assert Reservations.ledger().cash_held_cents == 100

    alternatives =
      for amount <- [10, 20, 30, 40],
          do: Map.merge(payment, %{"operation_id" => "race", "amount_cents" => amount})

    competing = concurrent_submit(repo, alternatives)
    assert Enum.count(competing, &(&1.status == "applied")) == 1
    assert Enum.count(competing, &(Map.get(&1, :code) == "operation_id_conflict")) == 3
    winner = Enum.find(competing, &(&1.status == "applied"))
    assert Reservations.ledger().cash_held_cents == 100 + winner.amount_cents
    assert Repo.aggregate(GroupStay.Operations.Entry, :count) == 3

    stale = Map.merge(payment, %{"operation_id" => "remembered-stale", "expected_revision" => 1})
    [rejection] = Reservations.submit([stale])
    assert rejection.code == "stale_revision"
    assert rejection.actual_revision == 3

    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, Keyword.put(options, :pool_size, 4)})
    Repo.put_dynamic_repo(restarted)
    assert Reservations.submit([operation, payment]) == [hd(results), hd(payments)]
    assert GroupStay.Operations.get_result("race") == winner
    assert Reservations.submit([stale]) == [rejection]
    assert GroupStay.Operations.get_result("remembered-stale") == rejection
    assert Reservations.get_group("retry-group").revision == 3
    assert Repo.aggregate(GroupStay.Operations.Entry, :count) == 4
    stop_supervised!(Repo)
  end

  defp concurrent_submit(repo, operations) do
    operations
    |> Task.async_stream(
      fn operation ->
        Repo.put_dynamic_repo(repo)
        [result] = Reservations.submit([operation])
        result
      end,
      max_concurrency: 8
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  test "unexpected journal failures return 500, roll back domain writes and abort only the remaining batch" do
    import Phoenix.ConnTest

    Repo.query!("""
    CREATE TRIGGER fail_journal BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected journal failure'); END
    """)

    opening = %{
      "operation_id" => "before-fault",
      "type" => "open_group",
      "group_id" => "fault-group",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "occurred_on" => "2027-01-01",
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10000}]
    }

    payment = %{
      "operation_id" => "fault",
      "type" => "record_cash_payment",
      "group_id" => "fault-group",
      "occurred_on" => "2027-01-02",
      "amount_cents" => 100
    }

    later = Map.put(payment, "operation_id", "after-fault")
    operations = [opening, payment, later]

    assert_error_sent 500, fn ->
      Phoenix.ConnTest.dispatch(
        build_conn(),
        GroupStayWeb.Endpoint,
        :post,
        "/api/v1/partner-batches",
        %{"operations" => operations}
      )
    end

    assert GroupStay.Operations.get_result("before-fault").revision == 1
    assert GroupStay.Operations.get_result("fault") == nil
    assert GroupStay.Operations.get_result("after-fault") == nil
    assert Reservations.get_group("fault-group").revision == 1
    assert Reservations.ledger().cash_held_cents == 0

    Repo.query!("DROP TRIGGER fail_journal")
    assert [%{revision: 1}, %{revision: 2}, %{revision: 3}] = Reservations.submit(operations)
    assert Reservations.ledger().cash_held_cents == 200
  end

  @tag :legacy
  test "upgrades original accounts using their booking date without changing balances" do
    for {id, booked, plan} <- [
          {"old", "2026-12-31", "flexible"},
          {"new", "2027-01-01", "flexible"},
          {"advance", "2027-01-01", "advance_purchase"}
        ] do
      Repo.query!(
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, status, revision, rooms, lodging_total_cents, deposit_due_cents,
          deposit_paid_cents, refunded_cents, retained_cents)
        VALUES (?, 'guest', 'hotel', ?, '2027-06-01', '2027-06-02', ?, 'active', 2, '[]', 1000, 200, 100, 0, 0)
        """,
        [id, booked, plan]
      )
    end

    Ecto.Migrator.run(Repo, Application.app_dir(:group_stay, "priv/repo/migrations"), :up,
      all: true,
      log: false
    )

    for {id, policy} <- [
          {"old", "flex-14"},
          {"new", "flex-30"},
          {"advance", "advance-nonrefundable"}
        ] do
      group = Reservations.get_group(id)
      assert group.policy_version == policy
      assert group.revision == 2
      assert group.deposit_paid_cents == 100
      assert group.credit_paid_cents == 0
      assert GroupStay.Reservations.Group.to_map(group).cash_paid_cents == 100
    end

    assert Reservations.ledger().cash_held_cents == 300
    assert Reservations.ledger().credit_liability_cents == 0
  end

  @tag :room_upgrade
  test "room upgrade places legacy cash and credit before journal funding in commit order" do
    legacy_group("mixed", "active", 180, 90, 0, 0, 0)

    for {lot, amount} <- [{1, 30}, {2, 60}] do
      Repo.query!(
        "INSERT INTO credit_lots (id, guest_id, source_operation_id, remaining_cents, expires_on) VALUES (?, 'guest', ?, 10, '2028-01-01')",
        [lot, "lot-#{lot}"]
      )

      Repo.query!(
        "INSERT INTO credit_allocations (group_id, credit_lot_id, amount_cents) VALUES ('mixed', ?, ?)",
        [lot, amount]
      )
    end

    # These dates deliberately disagree with journal order. Extra fields on a
    # non-funding operation must never cause it to be classified as funding.
    journal("credit", "apply_hotel_credit", "mixed", 50, "2027-03-01")
    journal("move", "reschedule_group", "mixed", 999, "2027-01-01")
    journal("payment", "record_cash_payment", "mixed", 60, "2027-01-01")
    migrate_rooms()

    group = Reservations.get_group("mixed")
    assert group.revision == 4
    assert group.deposit_paid_cents == 180
    assert group.credit_paid_cents == 90

    assert Enum.map(group.rooms, &{&1.cash_paid_cents, &1.credit_paid_cents}) == [
             {30, 70},
             {60, 20},
             {0, 0}
           ]

    assert Reservations.ledger(~D[2027-01-01]).credit_liability_cents == 110
    assert Reservations.ledger().cash_held_cents == 90
    assert {:ok, %{held_cents: 60, recorded_cents: 60}} = GroupStay.Payments.statement("payment")
    assert {:error, "operation_not_found"} = GroupStay.Payments.statement("legacy-payment")

    [result] =
      Reservations.submit([
        %{
          "operation_id" => "reduce",
          "type" => "reduce_cash_payment",
          "payment_operation_id" => "payment",
          "amount_cents" => 60,
          "occurred_on" => "2027-01-02",
          "expected_revision" => 4
        }
      ])

    assert result.revision == 5
    assert result.outstanding_deposit_cents == 180
    assert Enum.map(Reservations.get_group("mixed").rooms, & &1.cash_paid_cents) == [30, 0, 0]
  end

  @tag :room_upgrade
  test "upgrade reconstructs settled payment statements and senior-block credit entitlements" do
    legacy_group("converted", "cancelled", 0, 0, 0, 0, 5)
    legacy_group("refunded", "cancelled", 0, 0, 100, 0, 0)
    legacy_group("retained", "cancelled", 0, 0, 0, 100, 0)
    journal("converted-pay", "record_cash_payment", "converted", 1, "2027-01-01")
    journal("refunded-pay", "record_cash_payment", "refunded", 60, "2027-01-01")
    journal("retained-pay", "record_cash_payment", "retained", 80, "2027-01-01")
    journal("issue", "cancel_group", "converted", 0, "2027-01-02")

    Repo.query!(
      "INSERT INTO credit_lots (guest_id, source_operation_id, remaining_cents, expires_on) VALUES ('guest', 'issue', 6, '2028-01-02')"
    )

    migrate_rooms()

    assert {:ok, %{converted_to_credit_cents: 1}} = GroupStay.Payments.statement("converted-pay")
    assert {:ok, %{refunded_cents: 60}} = GroupStay.Payments.statement("refunded-pay")
    assert {:ok, %{retained_cents: 80}} = GroupStay.Payments.statement("retained-pay")
    assert Reservations.ledger().cash_refunded_cents == 100
    assert Reservations.ledger().cash_retained_cents == 100
    assert Reservations.ledger().cash_converted_to_credit_cents == 5

    [result] =
      Reservations.submit([
        %{
          "operation_id" => "cb",
          "type" => "charge_back_payment",
          "payment_operation_id" => "converted-pay",
          "occurred_on" => "2027-01-03"
        }
      ])

    assert result.charged_back_cents == 1
    assert result.revision == 5
    assert GroupStay.Credits.available("guest", ~D[2027-01-03]).available_cents == 4
    assert Reservations.ledger().cash_converted_to_credit_cents == 4
  end

  defp legacy_group(id, status, paid, credit, refunded, retained, converted) do
    rooms = for room <- ~w(a b c), do: %{"room_id" => room, "nightly_rate_cents" => 500}

    Repo.query!(
      """
      INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
        rate_plan, status, revision, rooms, lodging_total_cents, deposit_due_cents,
        deposit_paid_cents, refunded_cents, retained_cents, policy_version, credit_paid_cents, converted_to_credit_cents)
      VALUES (?, 'guest', 'hotel', '2027-01-01', '2027-06-01', '2027-06-02', 'flexible', ?, 4, ?, 1500, ?, ?, ?, ?, 'flex-30', ?, ?)
      """,
      [
        id,
        status,
        Jason.encode!(rooms),
        if(status == "active", do: 300, else: 0),
        paid,
        refunded,
        retained,
        credit,
        converted
      ]
    )
  end

  defp journal(id, type, group, amount, on) do
    submission = %{
      "operation_id" => id,
      "type" => type,
      "group_id" => group,
      "amount_cents" => amount,
      "occurred_on" => on
    }

    result = %{
      "operation_id" => id,
      "status" => "applied",
      "group_id" => group,
      "amount_cents" => amount,
      "revision" => 4
    }

    Repo.query!(
      "INSERT INTO operations (operation_id, type, submission, result) VALUES (?, ?, ?, ?)",
      [id, type, Jason.encode!(submission), Jason.encode!(result)]
    )
  end

  defp migrate_rooms do
    Ecto.Migrator.run(Repo, Application.app_dir(:group_stay, "priv/repo/migrations"), :up,
      all: true,
      log: false
    )
  end

  test "concurrent corrections serialize and chargeback survives restart", %{
    repo: repo,
    options: options
  } do
    opening = %{
      "operation_id" => "open",
      "type" => "open_group",
      "group_id" => "group",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "occurred_on" => "2027-01-01",
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "a", "nightly_rate_cents" => 1000}]
    }

    payment = %{
      "operation_id" => "pay",
      "type" => "record_cash_payment",
      "group_id" => "group",
      "occurred_on" => "2027-01-01",
      "amount_cents" => 200
    }

    [_, original] = Reservations.submit([opening, payment])

    reduction = %{
      "operation_id" => "reduce",
      "type" => "reduce_cash_payment",
      "payment_operation_id" => "pay",
      "occurred_on" => "2027-01-02",
      "amount_cents" => 50
    }

    results = concurrent_submit(repo, List.duplicate(reduction, 8))
    assert length(Enum.uniq(results)) == 1
    assert hd(results).revision == 3

    cb = %{
      "operation_id" => "cb",
      "type" => "charge_back_payment",
      "payment_operation_id" => "pay",
      "occurred_on" => "2027-01-03"
    }

    results = concurrent_submit(repo, List.duplicate(cb, 8))
    assert length(Enum.uniq(results)) == 1
    assert hd(results).revision == 4
    assert hd(results).charged_back_cents == 150
    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, Keyword.put(options, :pool_size, 4)})
    Repo.put_dynamic_repo(restarted)
    assert Reservations.submit([payment, cb]) == [original, hd(results)]

    assert {:ok, %{held_cents: 0, reduced_cents: 50, charged_back_cents: 150}} =
             GroupStay.Payments.statement("pay")

    assert Reservations.get_group("group").revision == 4
    stop_supervised!(Repo)
  end

  test "competing groups cannot spend the same credit lot", %{repo: repo} do
    opens =
      for id <- ["source", "one", "two"] do
        %{
          "operation_id" => "open-#{id}",
          "type" => "open_group",
          "group_id" => id,
          "guest_id" => "guest",
          "property_id" => "hotel",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-02",
          "rate_plan" => "flexible",
          "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10000}]
        }
      end

    Reservations.submit(
      opens ++
        [
          %{
            "operation_id" => "pay",
            "type" => "record_cash_payment",
            "group_id" => "source",
            "occurred_on" => "2027-01-01",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "cancel",
            "type" => "cancel_group",
            "group_id" => "source",
            "occurred_on" => "2027-01-01",
            "refund_method" => "hotel_credit"
          }
        ]
    )

    results =
      ["one", "two"]
      |> Task.async_stream(fn id ->
        Repo.put_dynamic_repo(repo)

        [result] =
          Reservations.submit([
            %{
              "operation_id" => "apply-#{id}",
              "type" => "apply_hotel_credit",
              "group_id" => id,
              "occurred_on" => "2027-01-01",
              "amount_cents" => 110
            }
          ])

        result
      end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "insufficient_credit")) == 1
    assert GroupStay.Credits.available("guest", ~D[2027-01-01]).available_cents == 0
    assert Reservations.ledger(~D[2027-01-01]).credit_liability_cents == 110
  end
end
