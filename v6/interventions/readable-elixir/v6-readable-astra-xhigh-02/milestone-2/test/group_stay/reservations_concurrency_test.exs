defmodule GroupStay.ReservationsConcurrencyTest do
  # These tests use real commits and separate connections. A shared sandbox
  # connection would hide the race between reading and updating a revision.
  use ExUnit.Case, async: false

  import GroupStay.PartnerOperations
  import GroupStay.MigrationHelpers

  alias GroupStay.{PartnerBatches, Repo, Reservations}
  alias GroupStay.HotelCredit.{Application, Lot}
  alias GroupStay.Reservations.{Group, Room}

  @repo_name __MODULE__.Repo

  setup_all do
    directory = Path.expand("tmp/concurrency-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)

    on_exit(fn ->
      if pid = Process.whereis(@repo_name), do: Supervisor.stop(pid)
      remove_database(directory)
    end)

    options = [
      name: @repo_name,
      database: Path.join(directory, "reservations.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 4
    ]

    # Establish the database and WAL with one connection before opening the pool.
    # Simultaneously setting the initial journal mode can itself race in SQLite.
    start_repo(Keyword.put(options, :pool_size, 1))
    Repo.put_dynamic_repo(@repo_name)
    Ecto.Migrator.run(Repo, migrations(), :up, all: true, log: false)
    Supervisor.stop(Process.whereis(@repo_name))
    start_repo(options)

    %{repo_options: options}
  end

  setup do
    Repo.put_dynamic_repo(@repo_name)
    Repo.delete_all(Application)
    Repo.delete_all(Lot)
    Repo.delete_all(Room)
    Repo.delete_all(Group)
    :ok
  end

  test "two payments with the same expected revision cannot both apply" do
    submit([open_group()])

    results =
      concurrently([payment(%{"expected_revision" => 1}), payment(%{"expected_revision" => 1})])

    assert Enum.count(results, &(&1.status == "applied")) == 1

    assert [%{code: :stale_revision, expected_revision: 1, actual_revision: 2}] =
             Enum.filter(results, &(&1.status == "rejected"))

    assert %Group{revision: 2, deposit_paid_cents: 1_000} = Reservations.get_group("group-81")
    assert Reservations.ledger().cash_held_cents == 1_000
  end

  test "unconditional simultaneous payments do not lose cash or revisions" do
    submit([open_group()])
    results = concurrently(List.duplicate(payment(), 12))

    assert Enum.all?(results, &(&1.status == "applied"))
    assert Enum.sort(Enum.map(results, & &1.revision)) == Enum.to_list(2..13)
    assert %Group{revision: 13, deposit_paid_cents: 12_000} = Reservations.get_group("group-81")
    assert Reservations.ledger().cash_held_cents == 12_000
  end

  test "simultaneous duplicate openings create only one group and its rooms" do
    results = concurrently(List.duplicate(open_group(), 4))

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == :group_already_exists)) == 3
    assert Repo.aggregate(Group, :count) == 1
    assert Repo.aggregate(Room, :count) == 2
  end

  test "a concurrent payment and cancellation settle cash exactly once" do
    submit([open_group()])
    results = concurrently([payment(), cancellation()])

    assert %{status: "applied"} = Enum.at(results, 1)
    group = Reservations.get_group("group-81")
    assert group.status == "cancelled"
    assert group.deposit_due_cents == 0

    case hd(results) do
      %{status: "applied"} ->
        assert group.revision == 3
        assert group.deposit_paid_cents == 1_000

      %{code: :group_not_active} ->
        assert group.revision == 2
        assert group.deposit_paid_cents == 0
    end

    assert Reservations.ledger() == %{
             cash_held_cents: 0,
             cash_refunded_cents: group.deposit_paid_cents,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }
  end

  test "commits, settlements and ordered rooms survive a repository restart and migration rerun",
       %{repo_options: options} do
    assert [_, _, %{status: "rejected"}, %{status: "applied"}] =
             submit([open_group(), payment(), payment(%{"amount_cents" => -1}), cancellation()])

    group = Reservations.get_group("group-81")
    ledger = Reservations.ledger()

    Supervisor.stop(Process.whereis(@repo_name))
    start_repo(options)
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []

    assert Reservations.get_group("group-81") == group
    assert Reservations.ledger() == ledger
    assert Enum.map(group.rooms, & &1.room_id) == ["room-b", "room-a"]
    assert ledger.cash_refunded_cents == 1_000
  end

  test "two groups competing for the same guest credit cannot overspend a lot" do
    seed_credit()
    submit([open_group(), open_group(%{"group_id" => "another"})])

    results = concurrently([credit_payment(), credit_payment(%{"group_id" => "another"})])

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == :insufficient_credit)) == 1
    assert GroupStay.HotelCredit.balance("guest-22", ~D[2026-11-01]).available_cents == 100
    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 1_100
    assert Enum.sum(Enum.map(Repo.all(Application), & &1.amount_cents)) == 1_000
  end

  test "credit applications with the same revision apply only once" do
    seed_credit()
    submit([open_group()])

    results =
      concurrently(
        List.duplicate(credit_payment(%{"amount_cents" => 100, "expected_revision" => 1}), 2)
      )

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == :stale_revision)) == 1
    assert Reservations.get_group("group-81").credit_paid_cents == 100
    assert GroupStay.HotelCredit.balance("guest-22", ~D[2026-11-01]).available_cents == 1_000
  end

  test "concurrent refundable cancellations restore a shared lot without losing credit" do
    seed_credit()

    submit([
      open_group(),
      open_group(%{"group_id" => "another"}),
      credit_payment(%{"amount_cents" => 500}),
      credit_payment(%{"group_id" => "another", "amount_cents" => 500})
    ])

    assert Enum.all?(
             concurrently([cancellation(), cancellation(%{"group_id" => "another"})]),
             &(&1.status == "applied")
           )

    assert GroupStay.HotelCredit.balance("guest-22", ~D[2026-11-01]).available_cents == 1_100
    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 1_100
  end

  test "credit identity, fixed policy and expired restoration survive a restart", %{
    repo_options: options
  } do
    seed_credit()

    submit([
      open_group(),
      credit_payment(),
      reschedule(%{"new_arrival_on" => "2028-01-01"})
    ])

    group = Reservations.get_group("group-81")
    lots = Repo.all(Lot)
    applications = Repo.all(Application)

    Supervisor.stop(Process.whereis(@repo_name))
    start_repo(options)
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []

    assert Reservations.get_group("group-81") == group
    assert group.policy_version == "flex-14"
    assert Repo.all(Lot) == lots
    assert Repo.all(Application) == applications
    assert Reservations.ledger(~D[2027-11-02]).credit_liability_cents == 1_000

    assert [%{status: "applied", revision: 4}] =
             submit([cancellation(%{"occurred_on" => "2027-11-02"})])

    assert Reservations.ledger(~D[2027-11-02]).credit_liability_cents == 0
    assert GroupStay.HotelCredit.balance("guest-22", ~D[2027-11-02]).available_cents == 0
  end

  test "a busy transaction start retries without recording a payment twice", %{
    repo_options: options
  } do
    submit([open_group()])
    contended_repo = __MODULE__.ContendedRepo
    pid = start_repo(Keyword.merge(options, name: contended_repo, pool_size: 1, busy_timeout: 1))
    on_exit(fn -> if Process.alive?(pid), do: Supervisor.stop(pid) end)

    parent = self()

    holder =
      Task.async(fn ->
        Repo.put_dynamic_repo(@repo_name)

        Repo.transaction(
          fn ->
            send(parent, :lock_acquired)

            receive do
              :release_lock -> :ok
            after
              5_000 -> raise "test never observed the competing BEGIN"
            end
          end,
          mode: :immediate
        )
      end)

    assert_receive :lock_acquired
    handler_id = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:group_stay, :repo, :query],
        &__MODULE__.release_on_busy/4,
        {parent, holder.pid}
      )

    try do
      ExUnit.CaptureLog.capture_log(fn ->
        attempt =
          Task.async(fn ->
            Repo.put_dynamic_repo(contended_repo)
            submit([payment(%{"expected_revision" => 1})])
          end)

        assert_receive :busy_begin, 2_000
        assert [%{status: "applied", revision: 2}] = Task.await(attempt)
        assert {:ok, :ok} = Task.await(holder)
      end)
    after
      :telemetry.detach(handler_id)
      send(holder.pid, :release_lock)
    end

    assert Reservations.get_group("group-81").deposit_paid_cents == 1_000
    assert Reservations.ledger().cash_held_cents == 1_000
  end

  @doc false
  def release_on_busy(
        _event,
        _measurements,
        %{query: "begin", result: {:error, %Exqlite.Error{}}},
        {parent, holder}
      ) do
    send(parent, :busy_begin)
    send(holder, :release_lock)
  end

  def release_on_busy(_event, _measurements, _metadata, _config), do: :ok

  defp seed_credit do
    assert [%{status: "applied"}, %{status: "applied"}, %{credit_issued_cents: 1_100}] =
             submit([
               open_group(%{"group_id" => "source"}),
               payment(%{"group_id" => "source"}),
               cancellation(%{"group_id" => "source", "refund_method" => "hotel_credit"})
             ])
  end

  defp concurrently(operations) do
    tasks =
      Enum.map(operations, fn operation ->
        Task.async(fn ->
          Repo.put_dynamic_repo(@repo_name)

          receive do
            :apply -> hd(submit([operation]))
          end
        end)
      end)

    Enum.each(tasks, &send(&1.pid, :apply))
    Task.await_many(tasks, 15_000)
  end

  defp submit(operations) do
    {:ok, results} = PartnerBatches.submit(%{"operations" => operations})
    results
  end

  defp start_repo(options) do
    {:ok, pid} = Repo.start_link(options)
    Process.unlink(pid)
    pid
  end

  # SQLite may finish removing WAL sidecars just after its connection processes
  # exit. Allow that native cleanup to finish before removing the directory.
  defp remove_database(directory, attempts \\ 10) do
    case File.rm_rf(directory) do
      {:ok, _files} ->
        :ok

      {:error, :eexist, _path} when attempts > 0 ->
        Process.sleep(10)
        remove_database(directory, attempts - 1)

      {:error, _reason, _path} ->
        File.rm_rf!(directory)
    end
  end
end
