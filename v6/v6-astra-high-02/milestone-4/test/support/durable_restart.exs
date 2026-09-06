# Invoked in separate BEAM instances by DurableOperationsPersistenceTest.
import ExUnit.Assertions
import Ecto.Query
alias GroupStay.{Operation, Repo, Reservations}

[phase, directory] = System.argv()
options = Application.fetch_env!(:group_stay, Repo)

Application.put_env(
  :group_stay,
  Repo,
  Keyword.merge(options, pool: DBConnection.ConnectionPool, pool_size: 2)
)

{:ok, _} = Application.ensure_all_started(:group_stay)

Ecto.Migrator.run(Repo, Application.app_dir(:group_stay, "priv/repo/migrations"), :up,
  all: true,
  log: false
)

operations = [
  %{
    "operation_id" => "missing",
    "type" => "cancel_group",
    "group_id" => "group",
    "occurred_on" => "2027-01-01"
  },
  %{
    "operation_id" => "open",
    "type" => "open_group",
    "group_id" => "group",
    "guest_id" => "guest",
    "property_id" => "hotel",
    "occurred_on" => "2027-01-01",
    "arrival_on" => "2027-06-01",
    "departure_on" => "2027-06-02",
    "rate_plan" => "flexible",
    "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 10000}]
  },
  %{
    "operation_id" => "pay",
    "type" => "record_cash_payment",
    "group_id" => "group",
    "occurred_on" => "2027-01-02",
    "amount_cents" => 100,
    "expected_revision" => 1
  },
  %{
    "operation_id" => "stale",
    "type" => "cancel_group",
    "group_id" => "group",
    "occurred_on" => "2027-01-02",
    "expected_revision" => 1
  },
  %{
    "operation_id" => "move",
    "type" => "reschedule_group",
    "group_id" => "group",
    "occurred_on" => "2027-01-02",
    "new_arrival_on" => "2028-06-01"
  },
  %{
    "operation_id" => "cancel",
    "type" => "cancel_group",
    "group_id" => "group",
    "occurred_on" => "2027-01-03",
    "refund_method" => "hotel_credit"
  }
]

room_open = %{
  "operation_id" => "room-open",
  "type" => "open_group",
  "group_id" => "rooms",
  "guest_id" => "room-guest",
  "property_id" => "hotel",
  "occurred_on" => "2027-01-01",
  "arrival_on" => "2027-06-01",
  "departure_on" => "2027-06-02",
  "rate_plan" => "flexible",
  "rooms" => for(i <- 0..2, do: %{"room_id" => "r#{i}", "nightly_rate_cents" => 500})
}

operations =
  operations ++
    [
      room_open,
      %{
        "operation_id" => "room-pay",
        "type" => "record_cash_payment",
        "group_id" => "rooms",
        "amount_cents" => 200,
        "occurred_on" => "2027-01-01"
      },
      %{
        "operation_id" => "room-reduce",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "room-pay",
        "amount_cents" => 25,
        "occurred_on" => "2027-01-01"
      },
      %{
        "operation_id" => "room-cancel",
        "type" => "cancel_rooms",
        "group_id" => "rooms",
        "room_ids" => ["r0"],
        "refund_method" => "hotel_credit",
        "occurred_on" => "2027-01-01"
      },
      Map.merge(room_open, %{"operation_id" => "consumer-open", "group_id" => "consumer"}),
      %{
        "operation_id" => "consumer-credit",
        "type" => "apply_hotel_credit",
        "group_id" => "consumer",
        "amount_cents" => 80,
        "occurred_on" => "2027-01-01"
      },
      %{
        "operation_id" => "room-chargeback",
        "type" => "charge_back_payment",
        "payment_operation_id" => "room-pay",
        "occurred_on" => "2027-01-01"
      }
    ]

audit = fn ->
  Repo.all(from o in Operation, order_by: o.id)
  |> Enum.map(&Map.take(&1, [:id, :operation_id, :type, :payload, :result]))
end

if phase == "write" do
  results = Reservations.submit(operations)

  assert Enum.map(Enum.take(results, 6), & &1.status) ==
           ~w(rejected applied applied rejected applied applied)

  assert Enum.all?(Enum.drop(results, 6), &(&1.status == "applied"))

  File.write!(
    Path.join(directory, "expected.json"),
    Jason.encode!(%{results: results, audit: audit.()})
  )
else
  expected = File.read!(Path.join(directory, "expected.json")) |> Jason.decode!()
  assert Jason.decode!(Jason.encode!(Reservations.submit(operations))) == expected["results"]

  for result <- expected["results"],
      do: assert(Reservations.get_operation(result["operation_id"]) == result)

  assert Jason.decode!(Jason.encode!(audit.())) == expected["audit"]
  assert Reservations.get_group("group").revision == 4
  assert Reservations.guest_credit("guest", ~D[2027-01-03]).available_cents == 110
  assert Reservations.ledger(~D[2027-01-03]).cash_converted_to_credit_cents == 100

  assert [%{code: "operation_id_conflict"}] =
           Reservations.submit([Map.put(Enum.at(operations, 3), "expected_revision", 4)])

  assert Jason.decode!(Jason.encode!(audit.())) == expected["audit"]
end

assert {:ok,
        %{
          recorded_cents: 200,
          held_cents: 0,
          converted_to_credit_cents: 0,
          reduced_cents: 25,
          charged_back_cents: 175
        }} = Reservations.get_payment("room-pay")

assert Reservations.get_group("rooms").revision == 5
assert Reservations.get_group("consumer").revision == 2
assert Reservations.ledger(~D[2027-01-03]).credit_shortfall_cents == 80
assert Reservations.ledger(~D[2027-01-03]).credit_liability_cents == 190
IO.puts("durable #{phase} verified")
