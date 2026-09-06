defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  import GroupStay.OperationFixtures
  import Ecto.Query

  alias GroupStay.{
    CreditAllocation,
    CreditLot,
    CreditEntitlement,
    Group,
    Repo,
    Room,
    RoomAllocation
  }

  for {booked, plan, policy, deadline} <- [
        {"2026-12-31", "flexible", "flex-14", "2027-02-15"},
        {"2027-01-01", "flexible", "flex-30", "2027-01-30"},
        {"2027-01-02", "flexible", "flex-30", "2027-01-30"},
        {"2026-12-31", "advance_purchase", "advance-nonrefundable", nil},
        {"2027-01-01", "advance_purchase", "advance-nonrefundable", nil}
      ] do
    test "booking #{booked} with #{plan} fixes policy #{policy}" do
      batch([
        open_operation(%{
          "occurred_on" => unquote(booked),
          "rate_plan" => unquote(plan),
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-04"
        })
      ])

      assert group()["policy_version"] == unquote(policy)
      assert group()["refundable_until"] == unquote(deadline)
    end
  end

  for {booked, cancel_on, refunded} <- [
        {"2026-12-31", "2027-02-15", 5000},
        {"2026-12-31", "2027-02-16", 0},
        {"2027-01-01", "2027-01-29", 5000},
        {"2027-01-01", "2027-01-30", 5000},
        {"2027-01-01", "2027-01-31", 0}
      ] do
    test "booking #{booked} cancelled on #{cancel_on} refunds #{refunded}" do
      batch([
        open_operation(%{
          "occurred_on" => unquote(booked),
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-04"
        }),
        operation("record_cash_payment", %{"amount_cents" => 5000})
      ])

      assert [result] = batch([operation("cancel_group", %{"occurred_on" => unquote(cancel_on)})])
      assert result["refunded_cents"] == unquote(refunded)
      assert result["retained_cents"] == 5000 - unquote(refunded)
      assert result["credit_issued_cents"] == 0
      assert ledger()["cash_refunded_cents"] == unquote(refunded)
    end
  end

  test "rescheduling across policy introduction and leap day keeps the original window" do
    for {id, booked, policy, deadline} <- [
          {"old", "2026-12-31", "flex-14", "2028-02-16"},
          {"new", "2027-01-01", "flex-30", "2028-01-31"}
        ] do
      batch([open_operation(%{"group_id" => id, "occurred_on" => booked})])

      assert [result] =
               batch([
                 operation("reschedule_group", %{
                   "group_id" => id,
                   "occurred_on" => "2028-01-01",
                   "new_arrival_on" => "2028-03-01",
                   "expected_revision" => 1
                 })
               ])

      assert result["policy_version"] == policy
      assert result["refundable_until"] == deadline
      assert result["new_departure_on"] == "2028-03-04"
      assert result["revision"] == 2
      assert group(id)["refundable_until"] == deadline
      assert group(id)["booked_on"] == booked
    end

    batch([open_operation(%{"rate_plan" => "advance_purchase"})])

    assert [%{"policy_version" => "advance-nonrefundable", "refundable_until" => nil}] =
             batch([operation("reschedule_group", %{"new_arrival_on" => "2028-03-01"})])
  end

  test "credit cancellation converts only paid cash and exposes inclusive 365-day expiry" do
    assert [_, _, result] = batch(issue_operations("source", "cancel-17", 5000, "2027-05-03"))

    assert result == %{
             "operation_id" => "cancel-17",
             "status" => "applied",
             "group_id" => "source",
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 5500,
             "revision" => 3
           }

    expected = %{
      "guest_id" => "guest-22",
      "available_cents" => 5500,
      "lots" => [
        %{
          "source_operation_id" => "cancel-17",
          "remaining_cents" => 5500,
          "expires_on" => "2028-05-02"
        }
      ]
    }

    assert credit("2028-05-02") == expected

    assert credit("2028-05-03") == %{
             "guest_id" => "guest-22",
             "available_cents" => 0,
             "lots" => []
           }

    assert ledger("2028-05-02") == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 5000,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 5500
           }

    assert ledger("2028-05-03")["credit_liability_cents"] == 0
    # Reads at a later date do not destroy lots for other as-of queries.
    assert credit("2028-05-02") == expected
    assert group("source")["cash_paid_cents"] == 0
    assert group("source")["deposit_due_cents"] == 0
  end

  test "the cash bonus uses exact half-up rounding, including large integer amounts" do
    for {amount, issued} <- [
          {1, 1},
          {4, 4},
          {5, 6},
          {15, 17},
          {9_007_199_254_740_995, 9_907_919_180_215_095}
        ] do
      operations = issue_operations("source-#{amount}", "cancel-#{amount}", amount, "2027-05-03")
      [opening | rest] = operations

      opening =
        Map.put(opening, "rooms", [%{"room_id" => "room", "nightly_rate_cents" => amount * 5}])

      assert [_, _, %{"credit_issued_cents" => ^issued}] = batch([opening | rest])
    end
  end

  test "unfunded credit cancellation issues no empty lot" do
    batch([open_operation()])

    assert [%{"credit_issued_cents" => 0, "revision" => 2}] =
             batch([
               operation("cancel_group", %{"refund_method" => "hotel_credit"})
             ])

    assert Repo.all(CreditLot) == []
    assert ledger()["credit_liability_cents"] == 0
  end

  test "non-refundable hotel-credit requests and invalid methods leave all state unchanged" do
    batch([open_operation(), operation("record_cash_payment", %{"amount_cents" => 5000})])

    for method <- [nil, "voucher", false, 1, %{}, []] do
      assert_rejected(
        operation("cancel_group", %{"refund_method" => method}),
        "invalid_refund_method"
      )
    end

    assert_rejected(
      operation("cancel_group", %{
        "refund_method" => "hotel_credit",
        "occurred_on" => "2026-11-27"
      }),
      "refund_method_not_available"
    )

    batch([open_operation(%{"group_id" => "advance", "rate_plan" => "advance_purchase"})])

    assert_rejected(
      operation("cancel_group", %{
        "group_id" => "advance",
        "refund_method" => "hotel_credit"
      }),
      "refund_method_not_available"
    )

    assert group()["status"] == "active"
    assert group()["revision"] == 2
  end

  test "lots are consumed by expiry then source identifier and repeated applications accumulate" do
    batch(
      issue_operations("late", "cancel-0", 100, "2027-05-04") ++
        issue_operations("second", "cancel-z", 100, "2027-05-03") ++
        issue_operations("first", "cancel-a", 100, "2027-05-03") ++ [future_group()]
    )

    assert Enum.map(credit()["lots"], & &1["source_operation_id"]) == [
             "cancel-a",
             "cancel-z",
             "cancel-0"
           ]

    assert [%{"revision" => 2, "outstanding_deposit_cents" => 19450}] =
             batch([
               operation("apply_hotel_credit", %{
                 "amount_cents" => 50,
                 "occurred_on" => "2027-05-04"
               })
             ])

    assert [%{"revision" => 3, "outstanding_deposit_cents" => 19350}] =
             batch([
               operation("apply_hotel_credit", %{
                 "amount_cents" => 100,
                 "occurred_on" => "2027-05-04",
                 "expected_revision" => 2
               })
             ])

    assert Enum.map(credit()["lots"], &{&1["source_operation_id"], &1["remaining_cents"]}) ==
             [{"cancel-z", 70}, {"cancel-0", 110}]

    assert group()["cash_paid_cents"] == 0
    assert group()["credit_paid_cents"] == 150
    assert group()["deposit_paid_cents"] == 150
    assert ledger()["cash_held_cents"] == 0
    assert ledger()["credit_liability_cents"] == 330

    batch([
      operation("cancel_group", %{"occurred_on" => "2027-05-04"})
    ])

    assert Enum.map(credit()["lots"], & &1["remaining_cents"]) == [110, 110, 110]
    assert ledger()["credit_liability_cents"] == 330
  end

  for method <- ["cash", "hotel_credit"] do
    test "refundable mixed funding with #{method} restores original credit without a second bonus" do
      batch(
        issue_operations("source", "original", 1000, "2027-05-03") ++
          [
            future_group(),
            operation("apply_hotel_credit", %{
              "amount_cents" => 800,
              "occurred_on" => "2027-06-01"
            }),
            operation("record_cash_payment", %{"amount_cents" => 505})
          ]
      )

      assert group()["cash_paid_cents"] == 505
      assert group()["credit_paid_cents"] == 800
      assert group()["deposit_paid_cents"] == 1305
      assert group()["outstanding_deposit_cents"] == 18195
      assert ledger()["cash_held_cents"] == 505
      assert ledger()["credit_liability_cents"] == 1100

      assert [result] =
               batch([
                 operation("cancel_group", %{
                   "refund_method" => unquote(method),
                   "occurred_on" => "2027-06-02",
                   "operation_id" => "new-credit",
                   "expected_revision" => 3
                 })
               ])

      assert result["revision"] == 4
      assert result["retained_cents"] == 0
      assert result["refunded_cents"] == if(unquote(method) == "cash", do: 505, else: 0)

      assert result["credit_issued_cents"] ==
               if(unquote(method) == "hotel_credit", do: 556, else: 0)

      assert hd(credit()["lots"])["remaining_cents"] == 1100
      assert hd(credit()["lots"])["expires_on"] == "2028-05-02"

      assert ledger()["credit_liability_cents"] ==
               if(unquote(method) == "cash", do: 1100, else: 1656)

      assert ledger()["cash_converted_to_credit_cents"] ==
               if(unquote(method) == "cash", do: 1000, else: 1505)

      assert group()["cash_paid_cents"] == 0
      assert group()["credit_paid_cents"] == 0
      assert group()["deposit_paid_cents"] == 0
    end
  end

  test "applied credit pauses expiry; restoration revives only lots still valid on cancellation" do
    batch(
      issue_operations("expired", "expired-lot", 1000, "2027-05-03") ++
        issue_operations("valid", "valid-lot", 1000, "2027-05-04") ++
        [
          future_group(),
          operation("apply_hotel_credit", %{"amount_cents" => 1700, "occurred_on" => "2028-05-02"})
        ]
    )

    assert ledger("2028-05-03")["credit_liability_cents"] == 2200
    assert ledger("2028-05-04")["credit_liability_cents"] == 1700
    assert credit("2028-05-04")["available_cents"] == 0

    assert [%{"credit_issued_cents" => 0, "refunded_cents" => 0, "retained_cents" => 0}] =
             batch([
               operation("cancel_group", %{
                 "occurred_on" => "2028-05-03",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert credit("2028-05-03")["lots"] == [
             %{
               "source_operation_id" => "valid-lot",
               "remaining_cents" => 1100,
               "expires_on" => "2028-05-03"
             }
           ]

    assert ledger("2028-05-03")["credit_liability_cents"] == 1100
    assert ledger("2028-05-04")["credit_liability_cents"] == 0
    # Expired restoration is permanently extinguished, including for backdated operations.
    assert Repo.get_by!(CreditLot, source_operation_id: "expired-lot").remaining_cents == 0
  end

  for plan <- ["flexible", "advance_purchase"] do
    test "non-refundable #{plan} cancellation retains cash and consumes applied credit" do
      batch(
        issue_operations("source", "original", 1000, "2027-05-03") ++
          [
            future_group(%{"rate_plan" => unquote(plan)}),
            operation("apply_hotel_credit", %{
              "amount_cents" => 800,
              "occurred_on" => "2027-06-01"
            }),
            operation("record_cash_payment", %{"amount_cents" => 500})
          ]
      )

      assert_rejected(
        operation("cancel_group", %{
          "occurred_on" => "2029-12-01",
          "refund_method" => "hotel_credit",
          "expected_revision" => 3
        }),
        "refund_method_not_available"
      )

      assert [
               %{
                 "refunded_cents" => 0,
                 "retained_cents" => 500,
                 "credit_issued_cents" => 0,
                 "revision" => 4
               }
             ] =
               batch([
                 operation("cancel_group", %{
                   "occurred_on" => "2029-12-01",
                   "expected_revision" => 3
                 })
               ])

      assert ledger("2028-05-02")["credit_liability_cents"] == 300
      assert ledger("2029-12-01")["credit_liability_cents"] == 0
      assert ledger()["cash_retained_cents"] == 500
      assert ledger()["cash_refunded_cents"] == 0
    end
  end

  test "credit uses the operation date, is guest-scoped, and follows all payment validation rules" do
    batch(
      issue_operations("source", "original", 1000, "2027-05-03") ++
        [
          future_group(),
          future_group(%{"group_id" => "other", "guest_id" => "other-guest"})
        ]
    )

    for amount <- [0, -1, 0.5, 10.0, "100", nil, true, %{}, []] do
      assert_rejected(
        operation("apply_hotel_credit", %{"amount_cents" => amount}),
        "invalid_amount"
      )
    end

    assert_rejected(
      operation("apply_hotel_credit", %{"amount_cents" => 19501}),
      "payment_exceeds_outstanding"
    )

    assert_rejected(
      operation("apply_hotel_credit", %{"amount_cents" => 1101}),
      "insufficient_credit"
    )

    assert_rejected(
      operation("apply_hotel_credit", %{"amount_cents" => 1, "group_id" => "other"}),
      "insufficient_credit"
    )

    assert_rejected(
      operation("apply_hotel_credit", %{"amount_cents" => 1, "occurred_on" => "2028-05-03"}),
      "insufficient_credit"
    )

    assert_rejected(
      operation("apply_hotel_credit", %{"amount_cents" => 1, "occurred_on" => "bad"}),
      "invalid_operation"
    )

    assert_rejected(operation("apply_hotel_credit"), "invalid_operation")

    assert [%{"revision" => 2}] =
             batch([
               operation("apply_hotel_credit", %{
                 "amount_cents" => 1100,
                 "occurred_on" => "2028-05-02"
               })
             ])

    assert credit()["lots"] == []
    assert ledger("2028-05-03")["credit_liability_cents"] == 1100
    batch([operation("cancel_group", %{"occurred_on" => "2028-05-03"})])
    assert_rejected(operation("apply_hotel_credit", %{"amount_cents" => 1}), "group_not_active")
  end

  test "credit cannot overfund deposits alongside cash, and other properties can redeem it" do
    batch(
      issue_operations("source", "original", 1000, "2027-05-03") ++
        [
          future_group(%{"property_id" => "another-hotel"}),
          operation("record_cash_payment", %{"amount_cents" => 19000})
        ]
    )

    assert_rejected(
      operation("apply_hotel_credit", %{"amount_cents" => 501}),
      "payment_exceeds_outstanding"
    )

    assert [%{"outstanding_deposit_cents" => 0}] =
             batch([operation("apply_hotel_credit", %{"amount_cents" => 500})])

    assert_rejected(
      operation("record_cash_payment", %{"amount_cents" => 1}),
      "payment_exceeds_outstanding"
    )

    assert ledger()["cash_held_cents"] == 19000
    assert ledger()["credit_liability_cents"] == 1100
  end

  test "a lot shared across groups restores only each group's funding and can be used again" do
    batch(
      issue_operations("source", "original", 1000, "2027-05-03") ++
        [
          future_group(),
          future_group(%{"group_id" => "second"}),
          operation("apply_hotel_credit", %{"amount_cents" => 600}),
          operation("apply_hotel_credit", %{"group_id" => "second", "amount_cents" => 500}),
          operation("cancel_group", %{"refund_method" => "hotel_credit"})
        ]
    )

    assert credit()["available_cents"] == 600
    assert group("second")["credit_paid_cents"] == 500
    assert ledger()["credit_liability_cents"] == 1100

    assert [%{"revision" => 3}, %{"revision" => 4, "credit_issued_cents" => 0}] =
             batch([
               operation("apply_hotel_credit", %{"group_id" => "second", "amount_cents" => 600}),
               operation("cancel_group", %{
                 "group_id" => "second",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert credit()["lots"] == [
             %{
               "source_operation_id" => "original",
               "remaining_cents" => 1100,
               "expires_on" => "2028-05-02"
             }
           ]

    assert ledger()["credit_liability_cents"] == 1100
    assert ledger()["cash_converted_to_credit_cents"] == 1000
    assert_rejected(operation("cancel_group", %{"group_id" => "second"}), "group_not_active")
  end

  test "unrepresentable credit expiry rejects atomically and does not prevent a cash settlement" do
    batch([
      open_operation(%{"arrival_on" => "9999-12-10", "departure_on" => "9999-12-13"}),
      operation("record_cash_payment", %{"amount_cents" => 100})
    ])

    assert_rejected(
      operation("cancel_group", %{
        "occurred_on" => "9999-01-01",
        "refund_method" => "hotel_credit",
        "expected_revision" => 2
      }),
      "invalid_operation"
    )

    assert [%{"refunded_cents" => 100, "revision" => 3}] =
             batch([
               operation("cancel_group", %{
                 "occurred_on" => "9999-01-01",
                 "expected_revision" => 2
               })
             ])
  end

  test "revision and group checks precede credit and refund rules and batch processing continues" do
    for type <- ["apply_hotel_credit", "cancel_group"] do
      assert_rejected(operation(type, %{"expected_revision" => 99}), "group_not_found")
    end

    batch([open_operation()])

    for op <- [
          operation("apply_hotel_credit", %{"amount_cents" => 5000}),
          operation("apply_hotel_credit"),
          operation("cancel_group", %{"refund_method" => "bad"}),
          operation("cancel_group", %{
            "refund_method" => "hotel_credit",
            "occurred_on" => "2026-12-01"
          })
        ] do
      result = assert_rejected(Map.put(op, "expected_revision", 2), "stale_revision")
      assert result["group_id"] == "group-81"
      assert result["expected_revision"] == 2
      assert result["actual_revision"] == 1
    end

    assert [
             %{"code" => "insufficient_credit"},
             %{"revision" => 2},
             %{"revision" => 3},
             %{"revision" => 1},
             %{"revision" => 2},
             %{"code" => "stale_revision", "actual_revision" => 2},
             %{"revision" => 3}
           ] =
             batch([
               operation("apply_hotel_credit", %{"amount_cents" => 1, "expected_revision" => 1}),
               operation("record_cash_payment", %{
                 "amount_cents" => 1000,
                 "expected_revision" => 1
               }),
               operation("cancel_group", %{
                 "refund_method" => "hotel_credit",
                 "expected_revision" => 2
               }),
               future_group(%{"group_id" => "target"}),
               operation("apply_hotel_credit", %{
                 "group_id" => "target",
                 "amount_cents" => 500,
                 "expected_revision" => 1
               }),
               operation("apply_hotel_credit", %{
                 "group_id" => "target",
                 "amount_cents" => 600,
                 "expected_revision" => 1
               }),
               operation("apply_hotel_credit", %{
                 "group_id" => "target",
                 "amount_cents" => 600,
                 "expected_revision" => 2
               })
             ])

    assert_rejected(
      operation("apply_hotel_credit", %{"amount_cents" => 1, "expected_revision" => 1}),
      "stale_revision"
    )
  end

  test "credit reads preserve identifiers and default both endpoints to the current UTC date" do
    guest = " Guest + café-22 "
    today = Date.utc_today()

    for {id, day} <- [{"expired", Date.add(today, -366)}, {"today", Date.add(today, -365)}] do
      batch(
        Enum.map(
          issue_operations(id, id, 100, Date.to_iso8601(day)),
          &Map.put(&1, "guest_id", guest)
        )
      )
    end

    assert credit(nil, guest) == credit(Date.to_iso8601(today), guest)
    assert credit(nil, guest)["guest_id"] == guest
    assert credit(nil, guest)["available_cents"] == 110
    assert ledger(nil) == ledger(Date.to_iso8601(today))
    assert ledger(nil)["credit_liability_cents"] == 110

    assert credit(nil, "missing") == %{
             "guest_id" => "missing",
             "available_cents" => 0,
             "lots" => []
           }

    for path <- ["/api/v1/ledger", "/api/v1/guests/guest-22/credit"],
        query <- ["on=bad", "on=2027-02-29", "on[]=2027-01-01", "on="] do
      assert build_conn() |> get(path <> "?" <> query) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_date"}}
    end
  end

  defp future_group(overrides \\ %{}) do
    open_operation(
      Map.merge(%{"arrival_on" => "2029-12-10", "departure_on" => "2029-12-13"}, overrides)
    )
  end

  defp issue_operations(group_id, source, amount, on) do
    [
      future_group(%{"group_id" => group_id}),
      operation("record_cash_payment", %{"group_id" => group_id, "amount_cents" => amount}),
      operation("cancel_group", %{
        "group_id" => group_id,
        "operation_id" => source,
        "occurred_on" => on,
        "refund_method" => "hotel_credit"
      })
    ]
  end

  defp batch(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group(id \\ "group-81"),
    do: read("/api/v1/groups/" <> URI.encode(id, &URI.char_unreserved?/1), nil)

  defp ledger(on \\ "2027-06-01"), do: read("/api/v1/ledger", on)

  defp credit(on \\ "2027-06-01", guest \\ "guest-22") do
    read("/api/v1/guests/" <> URI.encode(guest, &URI.char_unreserved?/1) <> "/credit", on)
  end

  defp read(path, on) do
    path = if on, do: path <> "?" <> URI.encode_query(%{"on" => on}), else: path
    build_conn() |> get(path) |> json_response(200) |> Map.fetch!("data")
  end

  defp assert_rejected(operation, code) do
    before = snapshot()
    assert [result] = batch([operation])
    assert result["status"] == "rejected"
    assert result["code"] == code
    assert snapshot() == before
    result
  end

  defp snapshot do
    for schema <- [Group, Room, CreditLot, CreditAllocation, CreditEntitlement, RoomAllocation] do
      Repo.all(from(row in schema)) |> Enum.sort()
    end
  end
end
