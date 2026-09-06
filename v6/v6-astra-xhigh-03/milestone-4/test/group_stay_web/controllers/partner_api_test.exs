defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase

  import GroupStay.OperationFixtures
  import Ecto.Query
  alias GroupStay.{Group, Repo, Room}

  test "opens a group and returns the complete persisted representation" do
    assert batch([open_operation(%{"operation_id" => "open-1", "expected_revision" => 500})]) == [
             %{
               "operation_id" => "open-1",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19500,
               "revision" => 1
             }
           ]

    assert group() == %{
             "group_id" => "group-81",
             "guest_id" => "guest-22",
             "property_id" => "ams-canal",
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
             "rate_plan" => "flexible",
             "policy_version" => "flex-14",
             "refundable_until" => "2026-11-26",
             "status" => "active",
             "revision" => 1,
             "rooms" => expected_rooms(),
             "lodging_total_cents" => 97500,
             "deposit_due_cents" => 19500,
             "deposit_paid_cents" => 0,
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19500
           }

    assert ledger() == empty_ledger()
  end

  test "identifiers are preserved and room identifiers are scoped to a group" do
    id = " Group + café-81 "

    batch([
      open_operation(%{
        "group_id" => id,
        "guest_id" => " Guest 22 ",
        "property_id" => "AMS-canal"
      }),
      open_operation()
    ])

    data = group(id)
    assert data["group_id"] == id
    assert data["guest_id"] == " Guest 22 "
    assert data["property_id"] == "AMS-canal"
    assert data["rooms"] == expected_rooms()
  end

  test "flexible deposits round each room independently using integer cents" do
    rooms =
      for {rate, id} <- [{2, "down-a"}, {2, "down-b"}, {3, "up-a"}, {3, "up-b"}] do
        %{"room_id" => id, "nightly_rate_cents" => rate}
      end

    assert [%{"deposit_due_cents" => 2}] =
             batch([
               open_operation(%{
                 "departure_on" => "2026-12-11",
                 "rooms" => rooms
               })
             ])

    assert group()["lodging_total_cents"] == 10

    # The two separately rounded 0.4-cent room deposits must sum to zero.
    assert [%{"deposit_due_cents" => 0}] =
             batch([
               open_operation(%{
                 "group_id" => "round-down",
                 "departure_on" => "2026-12-11",
                 "rooms" => Enum.take(rooms, 2)
               })
             ])

    assert [%{"deposit_due_cents" => 2}] =
             batch([
               open_operation(%{
                 "group_id" => "round-up",
                 "departure_on" => "2026-12-11",
                 "rooms" => Enum.drop(rooms, 2)
               })
             ])
  end

  test "advance purchase requires the full lodging price and zero rates remain usable" do
    assert [%{"deposit_due_cents" => 97500}] =
             batch([open_operation(%{"rate_plan" => "advance_purchase"})])

    assert [%{"deposit_due_cents" => 0}] =
             batch([
               open_operation(%{
                 "group_id" => "complimentary",
                 "rooms" => [%{"room_id" => "free", "nightly_rate_cents" => 0}]
               })
             ])

    assert ledger() == empty_ledger()
  end

  test "large representable amounts retain exact cent precision" do
    assert [%{"deposit_due_cents" => 1_801_439_850_948_199}] =
             batch([
               open_operation(%{
                 "departure_on" => "2026-12-11",
                 "rooms" => [
                   %{"room_id" => "large", "nightly_rate_cents" => 9_007_199_254_740_993}
                 ]
               })
             ])
  end

  test "invalid batches return 422 and empty batches succeed" do
    for body <- [%{}, %{"operations" => nil}, %{"operations" => %{}}, [], "operations", 1] do
      conn = post_json("/api/v1/partner-batches", body)
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    conn = post_json("/api/v1/partner-batches?operations[]=bad", %{})
    assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    assert batch([]) == []
  end

  test "missing group reads and empty ledger use the documented envelopes" do
    conn = get(build_conn(), "/api/v1/groups/missing")
    assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    assert ledger() == empty_ledger()
  end

  for {overrides, code} <- [
        {%{"arrival_on" => "2026-12-13"}, "invalid_stay"},
        {%{"departure_on" => "2026-12-09"}, "invalid_stay"},
        {%{"arrival_on" => "2026-02-29"}, "invalid_stay"},
        {%{"departure_on" => 20_261_213}, "invalid_stay"},
        {%{"occurred_on" => nil}, "invalid_stay"},
        {%{"rate_plan" => "unknown"}, "invalid_rate_plan"},
        {%{"rooms" => []}, "invalid_rooms"},
        {%{"rooms" => %{}}, "invalid_rooms"},
        {%{"rooms" => [nil]}, "invalid_rooms"},
        {%{"rooms" => [%{"room_id" => "r"}]}, "invalid_rooms"},
        {%{"rooms" => [%{"room_id" => "", "nightly_rate_cents" => 1}]}, "invalid_rooms"},
        {%{"rooms" => [%{"room_id" => "r", "nightly_rate_cents" => -1}]}, "invalid_rooms"},
        {%{"rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 1.5}]}, "invalid_rooms"},
        {%{"rooms" => [%{"room_id" => "r", "nightly_rate_cents" => "100"}]}, "invalid_rooms"},
        {%{"rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 9_223_372_036_854_775_807}]},
         "invalid_rooms"}
      ] do
    test "opening rejects #{inspect(overrides)} without writing" do
      assert_rejected(open_operation(unquote(Macro.escape(overrides))), unquote(code))
      assert [%{"status" => "applied"}] = batch([open_operation()])
    end
  end

  test "duplicate room IDs leave no partially created group or rooms" do
    room = %{"room_id" => "same", "nightly_rate_cents" => 1000}
    assert_rejected(open_operation(%{"rooms" => [room, room]}), "invalid_rooms")
    assert [%{"status" => "applied"}] = batch([open_operation()])
    assert_rejected(open_operation(), "group_already_exists")
  end

  test "malformed operations and missing required fields do not stop later operations" do
    batch([open_operation()])

    valid_operations = [
      open_operation(%{"group_id" => "second"}),
      operation("record_cash_payment", %{"amount_cents" => 1}),
      operation("reschedule_group", %{"new_arrival_on" => "2027-01-01"}),
      operation("cancel_group")
    ]

    for op <- valid_operations, field <- Map.keys(op) do
      malformed = op |> Map.put("operation_id", unique_operation_id()) |> Map.delete(field)
      assert_rejected(malformed, "invalid_operation")
    end

    for op <- [
          nil,
          [],
          42,
          true,
          "bad",
          %{},
          operation("unknown"),
          open_operation(%{"operation_id" => nil}),
          open_operation(%{"group_id" => 81}),
          open_operation(%{"guest_id" => nil}),
          open_operation(%{"property_id" => ""})
        ] do
      assert_rejected(op, "invalid_operation")
    end

    assert [
             %{"status" => "rejected", "code" => "invalid_operation"},
             %{"status" => "applied", "revision" => 2}
           ] = batch([nil, operation("record_cash_payment", %{"amount_cents" => 1})])
  end

  test "mixed batches commit successes in order and preserve state on each rejection" do
    assert [
             %{"operation_id" => "open-1", "status" => "applied", "revision" => 1},
             %{
               "operation_id" => "pay-a",
               "status" => "applied",
               "revision" => 2,
               "amount_cents" => 10000,
               "outstanding_deposit_cents" => 9500
             },
             %{"operation_id" => "pay-too-much", "code" => "payment_exceeds_outstanding"},
             %{
               "operation_id" => "pay-b",
               "status" => "applied",
               "revision" => 3,
               "outstanding_deposit_cents" => 0
             },
             %{"operation_id" => "pay-full", "code" => "payment_exceeds_outstanding"}
           ] =
             batch([
               open_operation(%{"operation_id" => "open-1"}),
               operation("record_cash_payment", %{
                 "operation_id" => "pay-a",
                 "amount_cents" => 10000
               }),
               operation("record_cash_payment", %{
                 "operation_id" => "pay-too-much",
                 "amount_cents" => 9501
               }),
               operation("record_cash_payment", %{
                 "operation_id" => "pay-b",
                 "amount_cents" => 9500,
                 "expected_revision" => 2
               }),
               operation("record_cash_payment", %{
                 "operation_id" => "pay-full",
                 "amount_cents" => 1
               })
             ])

    assert group()["deposit_paid_cents"] == 19500
    assert group()["revision"] == 3
    assert ledger() == Map.put(empty_ledger(), "cash_held_cents", 19500)
  end

  test "unusable payments leave all stored state untouched" do
    batch([open_operation()])

    for amount <- [0, -1, 0.5, 10.0, "100", nil, true, %{}, []] do
      assert_rejected(
        operation("record_cash_payment", %{"amount_cents" => amount}),
        "invalid_amount"
      )
    end

    assert_rejected(
      operation("record_cash_payment", %{"amount_cents" => 19501}),
      "payment_exceeds_outstanding"
    )
  end

  test "rescheduling preserves stay length, pricing, rooms and paid cash across a leap day" do
    batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 1234})
    ])

    before = group()
    before_ledger = ledger()

    assert [
             %{
               "new_arrival_on" => "2028-02-28",
               "new_departure_on" => "2028-03-02",
               "revision" => 3
             }
           ] =
             batch([operation("reschedule_group", %{"new_arrival_on" => "2028-02-28"})])

    assert group() ==
             Map.merge(before, %{
               "arrival_on" => "2028-02-28",
               "departure_on" => "2028-03-02",
               "refundable_until" => "2028-02-14",
               "revision" => 3
             })

    assert ledger() == before_ledger

    # Moving to the same arrival still counts as one applied operation.
    assert [%{"revision" => 4}] =
             batch([operation("reschedule_group", %{"new_arrival_on" => "2028-02-28"})])

    assert [
             %{
               "new_arrival_on" => "2026-12-31",
               "new_departure_on" => "2027-01-03",
               "revision" => 5
             }
           ] =
             batch([operation("reschedule_group", %{"new_arrival_on" => "2026-12-31"})])
  end

  test "unusable rescheduling dates leave the booking and ledger unchanged" do
    batch([open_operation()])

    for date <- ["2026-11-26", "2026-11-25", "2027-02-29", "bad", nil, 123, "9999-12-31"] do
      assert_rejected(operation("reschedule_group", %{"new_arrival_on" => date}), "invalid_stay")
    end

    assert_rejected(
      operation("reschedule_group", %{"occurred_on" => false, "new_arrival_on" => "2027-01-01"}),
      "invalid_stay"
    )
  end

  for {plan, date, refunded, retained} <- [
        {"flexible", "2026-11-25", 5000, 0},
        {"flexible", "2026-11-26", 5000, 0},
        {"flexible", "2026-11-27", 0, 5000},
        {"flexible", "2026-12-11", 0, 5000},
        {"advance_purchase", "2026-10-04", 0, 5000}
      ] do
    test "#{plan} cancellation on #{date} settles paid cash only" do
      batch([
        open_operation(%{"rate_plan" => unquote(plan)}),
        operation("record_cash_payment", %{"amount_cents" => 5000})
      ])

      assert batch([
               operation("cancel_group", %{
                 "operation_id" => "cancel_group-1",
                 "occurred_on" => unquote(date)
               })
             ]) == [
               %{
                 "operation_id" => "cancel_group-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "refunded_cents" => unquote(refunded),
                 "retained_cents" => unquote(retained),
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]

      data = group()
      assert data["status"] == "cancelled"
      assert data["deposit_due_cents"] == 0
      assert data["deposit_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 0
      assert data["lodging_total_cents"] == 0
      assert data["rooms"] == expected_rooms("cancelled")

      assert ledger() == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => unquote(refunded),
               "cash_retained_cents" => unquote(retained),
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_shortfall_cents" => 0,
               "credit_liability_cents" => 0
             }

      for op <- [
            operation("record_cash_payment", %{"amount_cents" => 1}),
            operation("reschedule_group", %{"new_arrival_on" => "2027-01-01"}),
            operation("cancel_group")
          ] do
        assert_rejected(op, "group_not_active")
      end
    end
  end

  test "unfunded cancellation has no cash effect and increments the revision" do
    assert [%{"revision" => 1}, %{"refunded_cents" => 0, "retained_cents" => 0, "revision" => 2}] =
             batch([open_operation(), operation("cancel_group")])

    assert ledger() == empty_ledger()
    assert group()["outstanding_deposit_cents"] == 0
  end

  test "cancellation uses the current arrival and ledger aggregates across groups" do
    batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 5000}),
      operation("reschedule_group", %{"new_arrival_on" => "2026-12-01"}),
      operation("cancel_group"),
      open_operation(%{"group_id" => "refunded"}),
      operation("record_cash_payment", %{"group_id" => "refunded", "amount_cents" => 7000}),
      operation("cancel_group", %{"group_id" => "refunded"}),
      open_operation(%{"group_id" => "held"}),
      operation("record_cash_payment", %{"group_id" => "held", "amount_cents" => 9000})
    ])

    assert ledger() == %{
             "cash_held_cents" => 9000,
             "cash_refunded_cents" => 7000,
             "cash_retained_cents" => 5000,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "missing groups take precedence over revision and domain validation" do
    for op <- [
          operation("record_cash_payment", %{"amount_cents" => -1}),
          operation("reschedule_group", %{"new_arrival_on" => "bad"}),
          operation("cancel_group", %{"occurred_on" => "bad"})
        ] do
      assert_rejected(Map.put(op, "expected_revision", 100), "group_not_found")
    end
  end

  test "revision checks precede domain validation and apply to cancelled groups" do
    batch([open_operation(), operation("record_cash_payment", %{"amount_cents" => 1})])

    for op <- [
          operation("record_cash_payment", %{"amount_cents" => -1}),
          operation("reschedule_group", %{"new_arrival_on" => "bad"}),
          operation("cancel_group", %{"occurred_on" => "bad"})
        ] do
      result = assert_rejected(Map.put(op, "expected_revision", 1), "stale_revision")

      assert result == %{
               "operation_id" => op["operation_id"],
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
    end

    for revision <- [nil, "2", 2.0, false, -1] do
      assert_rejected(
        operation("cancel_group", %{"expected_revision" => revision}),
        "stale_revision"
      )
    end

    assert [%{"revision" => 3}] = batch([operation("cancel_group", %{"expected_revision" => 2})])
    assert_rejected(operation("cancel_group", %{"expected_revision" => 2}), "stale_revision")
    assert_rejected(operation("cancel_group", %{"expected_revision" => 3}), "group_not_active")
  end

  test "revisions observe prior batch changes, and rejected operations never increment them" do
    assert [
             %{"revision" => 1},
             %{"revision" => 2},
             %{"code" => "stale_revision", "actual_revision" => 2},
             %{"code" => "invalid_stay"},
             %{"revision" => 3},
             %{"revision" => 4}
           ] =
             batch([
               open_operation(),
               operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1}),
               operation("cancel_group", %{"expected_revision" => 1}),
               operation("reschedule_group", %{
                 "new_arrival_on" => "bad",
                 "expected_revision" => 2
               }),
               operation("reschedule_group", %{
                 "new_arrival_on" => "2027-01-01",
                 "expected_revision" => 2
               }),
               operation("cancel_group", %{"expected_revision" => 3})
             ])
  end

  test "invalid common dates cannot mutate payments or cancellations" do
    batch([open_operation()])

    for type <- ["record_cash_payment", "cancel_group"] do
      assert_rejected(
        operation(type, %{"amount_cents" => 100, "occurred_on" => "not-a-date"}),
        "invalid_operation"
      )
    end
  end

  defp batch(operations) do
    "/api/v1/partner-batches"
    |> post_json(%{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp post_json(path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp group(id \\ "group-81") do
    build_conn()
    |> get("/api/v1/groups/#{URI.encode(id, &URI.char_unreserved?/1)}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger do
    build_conn() |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp expected_rooms(status \\ "active") do
    for room <- open_operation()["rooms"] do
      lodging = 3 * room["nightly_rate_cents"]

      Map.merge(room, %{
        "status" => status,
        "lodging_total_cents" => lodging,
        "deposit_due_cents" => if(status == "active", do: div(lodging, 5), else: 0),
        "cash_paid_cents" => 0,
        "credit_paid_cents" => 0
      })
    end
  end

  defp empty_ledger do
    %{
      "cash_held_cents" => 0,
      "cash_refunded_cents" => 0,
      "cash_retained_cents" => 0,
      "cash_converted_to_credit_cents" => 0,
      "cash_reduced_cents" => 0,
      "cash_charged_back_cents" => 0,
      "credit_shortfall_cents" => 0,
      "credit_liability_cents" => 0
    }
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
    {Repo.all(from g in Group, order_by: g.group_id), Repo.all(from r in Room, order_by: r.id)}
  end
end
