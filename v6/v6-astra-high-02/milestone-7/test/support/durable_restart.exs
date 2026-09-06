# Invoked in separate BEAM instances by DurableOperationsPersistenceTest.
import ExUnit.Assertions
import Ecto.Query
alias GroupStay.{FinanceReporting, Operation, Repo, Reservations}

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

operations =
  operations ++
    [
      Map.merge(room_open, %{
        "operation_id" => "transfer-source-open",
        "group_id" => "transfer-source"
      }),
      Map.merge(room_open, %{
        "operation_id" => "transfer-dest-open",
        "group_id" => "transfer-dest"
      }),
      %{
        "operation_id" => "transfer-pay1",
        "type" => "record_cash_payment",
        "group_id" => "transfer-source",
        "amount_cents" => 20,
        "occurred_on" => "2027-01-01"
      },
      %{
        "operation_id" => "transfer-pay2",
        "type" => "record_cash_payment",
        "group_id" => "transfer-source",
        "amount_cents" => 30,
        "occurred_on" => "2027-01-01"
      },
      %{
        "operation_id" => "transfer",
        "type" => "transfer_deposit",
        "source_group_id" => "transfer-source",
        "destination_group_id" => "transfer-dest",
        "amount_cents" => 40,
        "occurred_on" => "2027-01-01",
        "expected_revision" => 3,
        "destination_expected_revision" => 1
      },
      %{
        "operation_id" => "transfer-reduce",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "transfer-pay2",
        "amount_cents" => 30,
        "occurred_on" => "2027-01-01",
        "expected_revision" => 4
      }
    ]

# Exercise close replay and a late correction across separate BEAM processes too.
operations =
  operations ++
    [
      %{
        "operation_id" => "close-finance",
        "type" => "close_finance_period",
        "period_end_on" => "2027-01-03"
      },
      Map.merge(room_open, %{"operation_id" => "late-open", "group_id" => "late"}),
      %{
        "operation_id" => "late-pay",
        "type" => "record_cash_payment",
        "group_id" => "late",
        "amount_cents" => 25,
        "occurred_on" => "2027-01-01"
      }
    ]

audit = fn ->
  Repo.all(from o in Operation, order_by: o.id)
  |> Enum.map(&Map.take(&1, [:id, :operation_id, :type, :payload, :result]))
end

start = %{
  "operation_id" => "start-finance",
  "type" => "start_finance_reporting",
  "starts_on" => "2027-01-01"
}

assert [%{status: "applied"}] = Reservations.submit([start])

reports = fn ->
  for on <- ~w(2027-01-01 2027-01-02 2027-01-03 2027-01-04 2028-01-02 2028-01-04) do
    {:ok, report} = FinanceReporting.daily_report(on)
    report
  end
end

if phase == "write" do
  results = Reservations.submit(operations)

  assert Enum.map(Enum.take(results, 6), & &1.status) ==
           ~w(rejected applied applied rejected applied applied)

  assert Enum.all?(Enum.drop(results, 6), &(&1.status == "applied"))

  File.write!(
    Path.join(directory, "expected.json"),
    Jason.encode!(%{
      results: results,
      audit: audit.(),
      reports: reports.(),
      report_bytes: Enum.map(reports.(), &Jason.encode!/1)
    })
  )
else
  expected = File.read!(Path.join(directory, "expected.json")) |> Jason.decode!()
  assert Enum.map(reports.(), &Jason.encode!/1) == expected["report_bytes"]
  assert Jason.decode!(Jason.encode!(reports.())) == expected["reports"]
  assert Jason.decode!(Jason.encode!(Reservations.submit(operations))) == expected["results"]
  assert Jason.decode!(Jason.encode!(reports.())) == expected["reports"]

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

assert Reservations.get_group("transfer-source").revision == 5
assert Reservations.get_group("transfer-dest").revision == 3

assert {:ok,
        %{
          held_cents: 20,
          held_by_group: [
            %{group_id: "transfer-dest", amount_cents: 10},
            %{group_id: "transfer-source", amount_cents: 10}
          ]
        }} = Reservations.get_payment("transfer-pay1")

assert {:ok, %{held_cents: 0, reduced_cents: 30, held_by_group: []}} =
         Reservations.get_payment("transfer-pay2")

assert {:ok, %{status: "closed"}} = FinanceReporting.daily_report("2027-01-03")

assert {:ok,
        %{
          status: "open",
          late_adjustments: %{
            cash: [%{property_id: "hotel", movements: %{"received_cents" => 25}}]
          }
        }} = FinanceReporting.daily_report("2027-01-04")

if phase == "read" do
  {:ok, closed} = FinanceReporting.daily_report("2027-01-03")
  bytes = Jason.encode!(closed)

  assert [%{status: "applied"}, %{status: "applied"}] =
           Reservations.submit([
             %{
               "operation_id" => "close-again",
               "type" => "close_finance_period",
               "period_end_on" => "2027-01-04"
             },
             %{
               "operation_id" => "later-pay",
               "type" => "record_cash_payment",
               "group_id" => "late",
               "amount_cents" => 10,
               "occurred_on" => "2027-01-01"
             }
           ])

  {:ok, unchanged} = FinanceReporting.daily_report("2027-01-03")
  assert Jason.encode!(unchanged) == bytes

  assert {:ok, %{late_adjustments: %{cash: [%{movements: %{"received_cents" => 10}}]}}} =
           FinanceReporting.daily_report("2027-01-05")
end

IO.puts("durable #{phase} verified")
