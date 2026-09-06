defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase

  @booked_on "2026-10-03"

  describe "POST /api/v1/partner-batches - opening groups" do
    test "applies the API example and reports deposit and revision", %{conn: conn} do
      conn =
        post(conn, "/api/v1/partner-batches", %{
          operations: [
            %{
              "operation_id" => "op-1001",
              "type" => "open_group",
              "occurred_on" => @booked_on,
              "group_id" => "group-81",
              "guest_id" => "guest-22",
              "property_id" => "ams-canal",
              "arrival_on" => "2026-12-10",
              "departure_on" => "2026-12-13",
              "rate_plan" => "flexible",
              "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
              ]
            }
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 }
               ]
             }
    end

    test "an advance purchase room deposits its full lodging amount", %{conn: conn} do
      assert apply_open!(conn, "group-ap", rate_plan: "advance_purchase")["deposit_due_cents"] ==
               97_500
    end

    test "percentage deposits round to the nearest cent", %{conn: conn} do
      result =
        submit(conn, [
          open_op("group-round",
            rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 37}]
          )
        ])
        |> only_result()

      # lodging 37 * 3 nights = 111 cents; 20% = 22.2 -> rounds to 22
      assert result["deposit_due_cents"] == 22
      assert result["status"] == "applied"
    end

    test "rejects a duplicate group id without touching the original", %{conn: conn} do
      apply_open!(conn, "group-81")

      result =
        submit(conn, [open_op("group-81", operation_id: "op-open-group-81-again")])

      assert rejection(result, "group_already_exists")
      assert get_group(conn, "group-81")["revision"] == 1
    end

    test "rejects a stay without nights", %{conn: conn} do
      op = open_op("group-x", arrival_on: "2026-12-13", departure_on: "2026-12-13")

      assert rejection(submit(conn, [op]), "invalid_stay")
    end

    test "rejects an arrival after departure", %{conn: conn} do
      op = open_op("group-x", departure_on: "2026-12-09")

      assert rejection(submit(conn, [op]), "invalid_stay")
    end

    test "rejects empty or duplicate rooms", %{conn: conn} do
      assert rejection(submit(conn, [open_op("group-x", rooms: [])]), "invalid_rooms")

      duplicate = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-a", "nightly_rate_cents" => 16_000}
      ]

      assert rejection(
               submit(conn, [
                 open_op("group-x", operation_id: "op-open-dup-rooms", rooms: duplicate)
               ]),
               "invalid_rooms"
             )
    end

    test "rejects unknown rate plans", %{conn: conn} do
      assert rejection(
               submit(conn, [open_op("group-x", rate_plan: "super_saver")]),
               "invalid_rate_plan"
             )
    end

    test "a rejected open does not create the group", %{conn: conn} do
      submit(conn, [open_op("group-x", rooms: [])])

      assert get_conn(conn, "group-x") |> json_response(404) == %{
               "error" => %{"code" => "group_not_found"}
             }
    end
  end

  describe "POST /api/v1/partner-batches - recording cash" do
    test "applies cash to the outstanding deposit", %{conn: conn} do
      apply_open!(conn, "group-81")

      result = submit(conn, [payment_op("op-pay", "group-81", 10_000)]) |> only_result()

      assert result == %{
               "operation_id" => "op-pay",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 10_000,
               "outstanding_deposit_cents" => 9_500,
               "revision" => 2
             }
    end

    test "rejects amounts that are unusable as payments", %{conn: conn} do
      apply_open!(conn, "group-81")

      for {amount, index} <- Enum.with_index([0, -100, "1000", 10_000.50, nil]) do
        result = submit(conn, [payment_op("op-bad-#{index}", "group-81", amount)])
        assert rejection(result, "invalid_amount")
      end

      assert get_group(conn, "group-81")["deposit_paid_cents"] == 0
      assert get_group(conn, "group-81")["revision"] == 1
    end

    test "rejects payments above the outstanding deposit", %{conn: conn} do
      apply_open!(conn, "group-81")

      assert rejection(
               submit(conn, [payment_op("op-pay", "group-81", 19_501)]),
               "payment_exceeds_outstanding"
             )

      result = submit(conn, [payment_op("op-exact", "group-81", 19_500)]) |> only_result()
      assert result["outstanding_deposit_cents"] == 0
    end

    test "rejects payments to missing or inactive groups", %{conn: conn} do
      assert rejection(
               submit(conn, [payment_op("op-pay-missing", "missing", 500)]),
               "group_not_found"
             )

      apply_open!(conn, "group-81")
      submit(conn, [cancel_op("op-cancel", "group-81", "2026-12-01")])

      assert rejection(
               submit(conn, [payment_op("op-pay-inactive", "group-81", 500)]),
               "group_not_active"
             )
    end
  end

  describe "POST /api/v1/partner-batches - rescheduling" do
    test "shifts the departure date by the same number of days", %{conn: conn} do
      apply_open!(conn, "group-81")

      result = submit(conn, [reschedule_op("op-move", "group-81", "2026-12-20")]) |> only_result()

      assert result == %{
               "operation_id" => "op-move",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-06",
               "revision" => 2
             }

      group = get_group(conn, "group-81")
      assert group["arrival_on"] == "2026-12-20"
      assert group["departure_on"] == "2026-12-23"
      # length of stay unchanged, so price is unchanged
      assert group["lodging_total_cents"] == 97_500
      assert group["deposit_due_cents"] == 19_500
    end

    test "rejects arrivals on or before the operation date", %{conn: conn} do
      apply_open!(conn, "group-81")

      assert rejection(
               submit(conn, [reschedule_op("op-move-on", "group-81", "2026-10-03")]),
               "invalid_stay"
             )

      assert rejection(
               submit(conn, [reschedule_op("op-move-before", "group-81", "2026-09-01")]),
               "invalid_stay"
             )

      # an arrival after the operation date is fine
      assert only_result(submit(conn, [reschedule_op("op-move-after", "group-81", "2026-10-04")]))[
               "status"
             ] == "applied"
    end

    test "rejects unusable dates and inactive groups", %{conn: conn} do
      apply_open!(conn, "group-81")

      assert rejection(
               submit(conn, [reschedule_op("op-move-bad-date", "group-81", "not-a-date")]),
               "invalid_stay"
             )

      assert rejection(
               submit(conn, [reschedule_op("op-move-missing", "missing", "2027-01-01")]),
               "group_not_found"
             )

      submit(conn, [cancel_op("op-cancel", "group-81", "2026-10-20")])

      assert rejection(
               submit(conn, [reschedule_op("op-move-inactive", "group-81", "2027-01-01")]),
               "group_not_active"
             )
    end

    test "increments the revision even when booking fields do not visibly change", %{conn: conn} do
      apply_open!(conn, "group-81")

      result = submit(conn, [reschedule_op("op-move", "group-81", "2026-12-10")]) |> only_result()

      assert result["new_arrival_on"] == "2026-12-10"
      assert result["new_departure_on"] == "2026-12-13"
      assert result["revision"] == 2
    end
  end

  describe "POST /api/v1/partner-batches - cancelling" do
    test "refunds flexible cancellations at least 14 days before arrival", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay", "group-81", 5_000)])

      result = submit(conn, [cancel_op("op-cancel", "group-81", "2026-11-26")]) |> only_result()
      # 14 days before arrival 2026-12-10
      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 5_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }
    end

    test "retains cash when a flexible reservation is cancelled too late", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay", "group-81", 5_000)])

      result = submit(conn, [cancel_op("op-cancel", "group-81", "2026-11-27")]) |> only_result()

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 5_000
    end

    test "always retains cash for advance purchase reservations", %{conn: conn} do
      apply_open!(conn, "group-ap", rate_plan: "advance_purchase")
      submit(conn, [payment_op("op-pay", "group-ap", 90_000)])

      result = submit(conn, [cancel_op("op-cancel", "group-ap", "2026-10-05")]) |> only_result()

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 90_000
    end

    test "cancellation clears unpaid deposit and blocks later operations", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [cancel_op("op-cancel", "group-81", "2026-11-01")])

      group = get_group(conn, "group-81")
      assert group["status"] == "cancelled"
      assert group["outstanding_deposit_cents"] == 0

      assert rejection(submit(conn, [payment_op("op-p", "group-81", 100)]), "group_not_active")

      assert rejection(
               submit(conn, [reschedule_op("op-r", "group-81", "2026-12-20")]),
               "group_not_active"
             )

      assert rejection(
               submit(conn, [cancel_op("op-c", "group-81", "2026-11-02")]),
               "group_not_active"
             )

      assert get_group(conn, "group-81")["revision"] == 2
    end
  end

  describe "revisions" do
    test "each applied operation increments the revision once", %{conn: conn} do
      results =
        submit(conn, [
          open_op("group-81"),
          payment_op("op-pay-1", "group-81", 1_000),
          payment_op("op-pay-2", "group-81", 1_000),
          reschedule_op("op-move", "group-81", "2026-12-11"),
          cancel_op("op-cancel", "group-81", "2026-11-01")
        ])
        |> Map.fetch!("results")

      assert Enum.map(results, & &1["revision"]) == [1, 2, 3, 4, 5]
    end

    test "rejected operations never increment the revision", %{conn: conn} do
      apply_open!(conn, "group-81")

      submit(conn, [payment_op("op-bad", "group-81", 999_999)])

      assert get_group(conn, "group-81")["revision"] == 1
    end
  end

  describe "expected_revision" do
    test "rejects a stale revision with the documented fields", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay", "group-81", 1_000)])

      op = %{
        "operation_id" => "op-1002",
        "type" => "record_cash_payment",
        "occurred_on" => @booked_on,
        "group_id" => "group-81",
        "amount_cents" => 1_000,
        "expected_revision" => 1
      }

      assert submit(conn, [op])["results"] == [
               %{
                 "operation_id" => "op-1002",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ]

      # the rejected operation left the group and ledger unchanged
      group = get_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 1_000
      assert group["revision"] == 2
      assert ledger(conn)["cash_held_cents"] == 1_000
    end

    test "checks the revision against earlier operations in the same batch", %{conn: conn} do
      results =
        submit(conn, [
          open_op("group-81"),
          payment_op("op-ok", "group-81", 1_000) |> Map.put("expected_revision", 1),
          payment_op("op-stale", "group-81", 1_000) |> Map.put("expected_revision", 1),
          payment_op("op-current", "group-81", 1_000) |> Map.put("expected_revision", 2)
        ])
        |> Map.fetch!("results")

      assert Enum.map(results, &{&1["status"], &1["code"], &1["revision"]}) == [
               {"applied", nil, 1},
               {"applied", nil, 2},
               {"rejected", "stale_revision", nil},
               {"applied", nil, 3}
             ]
    end

    test "resolves group existence before comparing revisions", %{conn: conn} do
      op = payment_op("op-pay", "missing", 1_000) |> Map.put("expected_revision", 7)

      assert rejection(submit(conn, [op]), "group_not_found")
    end

    test "rejects a stale revision before other domain rules", %{conn: conn} do
      apply_open!(conn, "group-81")

      op =
        payment_op("op-pay", "group-81", 999_999)
        |> Map.put("expected_revision", 99)

      assert rejection(submit(conn, [op]), "stale_revision")
      assert rejection(submit(conn, [reschedule_stale_op()]), "stale_revision")
      assert rejection(submit(conn, [cancel_stale_op()]), "stale_revision")
    end

    defp reschedule_stale_op do
      reschedule_op("op-move", "group-81", "2026-12-20") |> Map.put("expected_revision", 99)
    end

    defp cancel_stale_op do
      cancel_op("op-cancel", "group-81", "2026-11-01") |> Map.put("expected_revision", 99)
    end
  end

  describe "batch handling" do
    test "returns one result per operation in order and keeps processing after rejections", %{
      conn: conn
    } do
      results =
        submit(conn, [
          open_op("group-81"),
          open_op("group-81", operation_id: "op-open-group-81-again"),
          payment_op("op-pay-missing", "missing", 1_000),
          payment_op("op-pay", "group-81", 1_000),
          %{"operation_id" => "op-junk", "type" => "teleport_group", "occurred_on" => @booked_on},
          reschedule_op("op-move", "group-81", "2026-12-11")
        ])
        |> Map.fetch!("results")

      assert Enum.map(results, & &1["status"]) == [
               "applied",
               "rejected",
               "rejected",
               "applied",
               "rejected",
               "applied"
             ]

      assert Enum.map(results, & &1["code"]) == [
               nil,
               "group_already_exists",
               "group_not_found",
               nil,
               "invalid_operation",
               nil
             ]

      assert Enum.map(results, & &1["operation_id"]) == [
               "op-open-group-81",
               "op-open-group-81-again",
               "op-pay-missing",
               "op-pay",
               "op-junk",
               "op-move"
             ]

      assert get_group(conn, "group-81")["revision"] == 3
    end

    test "returns 422 for a body without an operations array", %{conn: conn} do
      assert conn |> post("/api/v1/partner-batches", %{}) |> json_response(422) == %{
               "error" => %{"code" => "invalid_batch"}
             }

      assert conn
             |> post("/api/v1/partner-batches", %{"operations" => "nope"})
             |> json_response(422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "rejects operations that cannot be identified or applied", %{conn: conn} do
      apply_open!(conn, "group-81")

      results =
        submit(conn, [
          %{"operation_id" => "op-no-type", "occurred_on" => @booked_on},
          %{"operation_id" => "op-no-date", "type" => "cancel_group", "group_id" => "group-81"},
          %{"type" => "cancel_group", "occurred_on" => @booked_on, "group_id" => "group-81"},
          "not-a-map",
          %{
            "operation_id" => "op-bad-room",
            "type" => "open_group",
            "occurred_on" => @booked_on,
            "group_id" => "group-y",
            "guest_id" => "guest-22",
            "property_id" => "ams-canal",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-13",
            "rate_plan" => "flexible",
            "rooms" => [%{"room_id" => "room-a"}]
          }
        ])
        |> Map.fetch!("results")

      assert Enum.all?(
               results,
               &(&1["status"] == "rejected" and &1["code"] == "invalid_operation")
             )

      # none of the rejected operations changed anything
      assert get_group(conn, "group-81")["revision"] == 1

      assert get_conn(conn, "group-y") |> json_response(404) == %{
               "error" => %{"code" => "group_not_found"}
             }
    end

    test "a rejected payment leaves the ledger untouched and later operations proceed", %{
      conn: conn
    } do
      apply_open!(conn, "group-81")

      results =
        submit(conn, [
          payment_op("op-too-much", "group-81", 999_999),
          payment_op("op-ok", "group-81", 2_000)
        ])
        |> Map.fetch!("results")

      assert [rejected, applied] = results
      assert rejected["code"] == "payment_exceeds_outstanding"
      assert applied["amount_cents"] == 2_000
      assert ledger(conn)["cash_held_cents"] == 2_000
    end
  end

  describe "read endpoints" do
    test "GET /api/v1/groups/:group_id renders the group", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay", "group-81", 10_000)])

      group = get_group(conn, "group-81")

      assert group == %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 2,
               "booked_on" => @booked_on,
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "status" => "active",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26",
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 10_000,
               "cash_paid_cents" => 10_000,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 9_500
             }
    end

    test "GET /api/v1/groups/:group_id returns 404 for a missing group", %{conn: conn} do
      assert get_conn(conn, "missing") |> json_response(404) == %{
               "error" => %{"code" => "group_not_found"}
             }
    end

    test "GET /api/v1/ledger starts at zero and follows cash movements", %{conn: conn} do
      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }

      apply_open!(conn, "group-refundable")
      apply_open!(conn, "group-retained", rate_plan: "advance_purchase")
      submit(conn, [payment_op("op-p1", "group-refundable", 5_000)])
      submit(conn, [payment_op("op-p2", "group-retained", 8_000)])

      assert ledger(conn)["cash_held_cents"] == 13_000

      submit(conn, [cancel_op("op-c1", "group-refundable", "2026-11-01")])
      assert ledger(conn)["cash_refunded_cents"] == 5_000

      submit(conn, [cancel_op("op-c2", "group-retained", "2026-11-01")])
      assert ledger(conn)["cash_retained_cents"] == 8_000

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 8_000,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end

    test "unpaid deposit requirements never appear in ledger totals", %{conn: conn} do
      apply_open!(conn, "group-81")

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end
  end

  describe "policy versions" do
    test "flexible groups booked before 2027-01-01 keep the 14-day window", %{conn: conn} do
      group =
        open_and_get(conn, "group-old",
          occurred_on: "2026-12-31",
          arrival_on: "2027-03-01",
          departure_on: "2027-03-04"
        )

      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2027-02-15"

      # the window still governs refundability
      submit(conn, [payment_op("op-pay", "group-old", 5_000)])

      result = only_result(submit(conn, [cancel_op("op-cancel", "group-old", "2027-02-15")]))
      assert result["refunded_cents"] == 5_000
    end

    test "flexible groups booked on or after 2027-01-01 use a 30-day window", %{conn: conn} do
      group =
        open_and_get(conn, "group-new",
          occurred_on: "2027-01-01",
          arrival_on: "2027-03-01",
          departure_on: "2027-03-04"
        )

      assert group["policy_version"] == "flex-30"
      assert group["refundable_until"] == "2027-01-30"

      submit(conn, [payment_op("op-pay", "group-new", 5_000)])

      # 20 days before arrival is no longer refundable under flex-30
      result = only_result(submit(conn, [cancel_op("op-cancel", "group-new", "2027-02-09")]))
      assert result["retained_cents"] == 5_000

      # cancellation exactly on refundable_until is refundable
      apply_open!(conn, "group-edge",
        occurred_on: "2027-01-01",
        arrival_on: "2027-03-01",
        departure_on: "2027-03-04"
      )

      submit(conn, [payment_op("op-pay2", "group-edge", 5_000)])

      result = only_result(submit(conn, [cancel_op("op-cancel2", "group-edge", "2027-01-30")]))
      assert result["refunded_cents"] == 5_000
    end

    test "advance purchase groups are advance-nonrefundable without a refundable date", %{
      conn: conn
    } do
      apply_open!(conn, "group-ap", rate_plan: "advance_purchase")
      group = get_group(conn, "group-ap")

      assert group["policy_version"] == "advance-nonrefundable"
      assert group["refundable_until"] == nil
    end

    test "rescheduling keeps the fixed policy version and recomputes refundable_until", %{
      conn: conn
    } do
      apply_open!(conn, "group-81")

      result = submit(conn, [reschedule_op("op-move", "group-81", "2026-12-20")]) |> only_result()

      assert result["policy_version"] == "flex-14"
      assert result["refundable_until"] == "2026-12-06"

      group = get_group(conn, "group-81")
      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2026-12-06"
    end
  end

  describe "issuing hotel credit on cancellation" do
    test "a refundable cancellation with hotel credit converts cash into a bonus lot", %{
      conn: conn
    } do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay", "group-81", 10_000)])

      result =
        only_result(submit(conn, [credit_cancel_op("op-cancel", "group-81", "2026-11-26")]))

      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 11_000,
               "revision" => 3
             }

      # cash moved from held to converted-to-credit and became the liability
      assert ledger(conn)["cash_held_cents"] == 0
      assert ledger(conn)["cash_refunded_cents"] == 0
      assert ledger(conn)["cash_retained_cents"] == 0
      assert ledger(conn)["cash_converted_to_credit_cents"] == 10_000
      assert ledger(conn)["credit_liability_cents"] == 11_000

      # available through 365 days after cancellation, expires the following day
      assert guest_credit(conn, "guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 11_000,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel",
                   "remaining_cents" => 11_000,
                   "expires_on" => "2027-11-27"
                 }
               ]
             }
    end

    test "the bonus applies standard rounding to the extra ten percent", %{conn: conn} do
      result = issue_credit(conn, "op-cancel", "group-src", 5, "2026-11-26")

      # 5 cents of cash becomes 5.5 cents of credit, rounded up to 6
      assert result["credit_issued_cents"] == 6
    end

    test "hotel credit is refused for a non-refundable cancellation", %{conn: conn} do
      apply_open!(conn, "group-ap", rate_plan: "advance_purchase")
      submit(conn, [payment_op("op-pay", "group-ap", 90_000)])

      result =
        submit(conn, [credit_cancel_op("op-cancel", "group-ap", "2026-10-05")])
        |> only_result()

      assert result["status"] == "rejected"
      assert result["code"] == "refund_method_not_available"

      # the group stays active and its cash is untouched
      group = get_group(conn, "group-ap")
      assert group["status"] == "active"
      assert group["revision"] == 2
      assert ledger(conn)["cash_held_cents"] == 90_000
    end

    test "an unknown refund method is rejected as an invalid operation", %{conn: conn} do
      apply_open!(conn, "group-81")

      op =
        cancel_op("op-cancel", "group-81", "2026-11-26")
        |> Map.put("refund_method", "gift_card")

      assert rejection(submit(conn, [op]), "invalid_operation")
      assert get_group(conn, "group-81")["status"] == "active"
      assert get_group(conn, "group-81")["revision"] == 1
    end
  end

  describe "applying hotel credit" do
    test "applies credit to an active group's outstanding deposit", %{conn: conn} do
      issue_credit(conn, "op-cancel-17", "group-src", 10_000, "2026-11-26")
      apply_open!(conn, "group-81")

      result = only_result(submit(conn, [credit_op("op-use", "group-81", 4_000)]))

      assert result == %{
               "operation_id" => "op-use",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 4_000,
               "outstanding_deposit_cents" => 15_500,
               "revision" => 2
             }

      group = get_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 4_000
      assert group["cash_paid_cents"] == 0
      assert group["credit_paid_cents"] == 4_000

      # applying credit redeems it into the deposit without changing the liability
      assert ledger(conn)["credit_liability_cents"] == 11_000
      assert guest_credit(conn, "guest-22")["available_cents"] == 7_000
    end

    test "consumes lots by earliest expiry then source_operation_id", %{conn: conn} do
      issue_credit(conn, "op-cancel-b", "group-b", 1_000, "2026-11-26")
      issue_credit(conn, "op-cancel-a", "group-a", 1_000, "2026-11-26")

      # an earlier-expiring lot from a different cancellation date
      issue_credit(conn, "op-cancel-c", "group-c", 1_000, "2026-05-01")

      lots = guest_credit(conn, "guest-22")["lots"]

      assert Enum.map(lots, & &1["source_operation_id"]) == [
               "op-cancel-c",
               "op-cancel-a",
               "op-cancel-b"
             ]

      apply_open!(conn, "group-81")
      submit(conn, [credit_op("op-use", "group-81", 1_200)])

      lots = guest_credit(conn, "guest-22")["lots"]

      assert Enum.map(lots, &{&1["source_operation_id"], &1["remaining_cents"]}) == [
               {"op-cancel-a", 1_000},
               {"op-cancel-b", 1_100}
             ]
    end

    test "rejects amounts the guest cannot cover", %{conn: conn} do
      issue_credit(conn, "op-cancel-17", "group-src", 1_000, "2026-11-26")
      apply_open!(conn, "group-81")

      assert rejection(
               submit(conn, [credit_op("op-use", "group-81", 1_101)]),
               "insufficient_credit"
             )

      assert get_group(conn, "group-81")["revision"] == 1
      assert get_group(conn, "group-81")["deposit_paid_cents"] == 0
    end

    test "always evaluates expiry using the operation's occurred_on date", %{conn: conn} do
      issue_credit(conn, "op-cancel-17", "group-src", 10_000, "2026-05-01")
      apply_open!(conn, "group-81")

      # the lot expires on 2027-05-02, so it cannot be applied that day
      op = credit_op("op-late", "group-81", 5_000, occurred_on: "2027-05-02")

      assert rejection(submit(conn, [op]), "insufficient_credit")

      # but it can be applied the day before it expires
      op = credit_op("op-early", "group-81", 5_000, occurred_on: "2027-05-01")

      assert only_result(submit(conn, [op]))["status"] == "applied"
    end

    test "rejects credit above the outstanding deposit or with unusable amounts", %{conn: conn} do
      issue_credit(conn, "op-cancel-17", "group-src", 20_000, "2026-05-01")
      apply_open!(conn, "group-81")

      assert rejection(
               submit(conn, [credit_op("op-over", "group-81", 19_501)]),
               "payment_exceeds_outstanding"
             )

      for {amount, index} <- Enum.with_index([0, -100, "1000", 1_000.50, nil]) do
        assert rejection(
                 submit(conn, [credit_op("op-bad-#{index}", "group-81", amount)]),
                 "invalid_amount"
               )
      end

      assert get_group(conn, "group-81")["revision"] == 1
    end

    test "rejects missing or inactive groups", %{conn: conn} do
      assert rejection(
               submit(conn, [credit_op("op-use-missing", "missing", 500)]),
               "group_not_found"
             )

      apply_open!(conn, "group-81")
      submit(conn, [cancel_op("op-cancel", "group-81", "2026-11-26")])

      assert rejection(
               submit(conn, [credit_op("op-use-inactive", "group-81", 500)]),
               "group_not_active"
             )
    end

    test "follows the revision contract", %{conn: conn} do
      issue_credit(conn, "op-cancel-17", "group-src", 10_000, "2026-11-26")
      apply_open!(conn, "group-81")

      stale = credit_op("op-stale", "group-81", 4_000) |> Map.put("expected_revision", 99)

      assert rejection(submit(conn, [stale]), "stale_revision")
      assert get_group(conn, "group-81")["revision"] == 1

      current = credit_op("op-current", "group-81", 4_000) |> Map.put("expected_revision", 1)
      assert only_result(submit(conn, [current]))["revision"] == 2
    end
  end

  describe "settling a group funded by credit" do
    test "a refundable cancellation restores applied credit without a second bonus", %{conn: conn} do
      issue_credit(conn, "op-cancel-17", "group-src", 10_000, "2026-11-26")
      apply_open!(conn, "group-81")
      submit(conn, [credit_op("op-use", "group-81", 4_000)])

      result = only_result(submit(conn, [cancel_op("op-cancel", "group-81", "2026-11-26")]))

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      group = get_group(conn, "group-81")
      assert group["status"] == "cancelled"
      assert group["credit_paid_cents"] == 0
      assert group["cash_paid_cents"] == 0

      # the credit returns to its original lot with its original expiry
      assert guest_credit(conn, "guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 11_000,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-17",
                   "remaining_cents" => 11_000,
                   "expires_on" => "2027-11-27"
                 }
               ]
             }

      # restoring credit does not change the liability
      assert ledger(conn)["credit_liability_cents"] == 11_000
    end

    test "restored credit past its expiry disappears instead of becoming available", %{conn: conn} do
      # lot issued on 2026-05-01 expires on 2027-05-02
      issue_credit(conn, "op-cancel-e", "group-e", 10_000, "2026-05-01")

      apply_open!(conn, "group-late",
        occurred_on: "2026-06-01",
        arrival_on: "2028-03-01",
        departure_on: "2028-03-04"
      )

      assert only_result(submit(conn, [credit_op("op-use", "group-late", 11_000)]))[
               "status"
             ] == "applied"

      assert ledger(conn)["credit_liability_cents"] == 11_000

      # refundable cancellation on the very day the lot expires
      result = only_result(submit(conn, [cancel_op("op-cancel", "group-late", "2027-05-02")]))

      assert result["status"] == "applied"
      assert guest_credit(conn, "guest-22")["available_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "mixed funding: cash becomes a bonus lot and credit returns untouched", %{conn: conn} do
      issue_credit(conn, "op-cancel-17", "group-src", 5_000, "2026-11-26")
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay", "group-81", 2_000)])
      submit(conn, [credit_op("op-use", "group-81", 4_000)])

      result =
        only_result(submit(conn, [credit_cancel_op("op-cancel", "group-81", "2026-11-06")]))

      # only the cash portion gets the bonus
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 2_200

      # cumulative: 5_000 from the earlier credit cancellation plus these 2_000
      assert ledger(conn)["cash_converted_to_credit_cents"] == 7_000

      # the cash portion became a new lot and the applied credit returned to
      # its original lot in full, without a second bonus
      lots = guest_credit(conn, "guest-22")["lots"]

      assert Enum.map(lots, &{&1["source_operation_id"], &1["remaining_cents"]}) == [
               {"op-cancel", 2_200},
               {"op-cancel-17", 5_500}
             ]

      assert ledger(conn)["credit_liability_cents"] == 7_700
    end

    test "a non-refundable cancellation retains cash and consumes applied credit", %{conn: conn} do
      issue_credit(conn, "op-cancel-17", "group-src", 10_000, "2026-11-26")

      apply_open!(conn, "group-retained", rate_plan: "advance_purchase")
      submit(conn, [payment_op("op-pay", "group-retained", 1_000)])
      submit(conn, [credit_op("op-use", "group-retained", 4_000)])

      result = only_result(submit(conn, [cancel_op("op-cancel", "group-retained", "2026-11-01")]))

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 1_000
      assert result["credit_issued_cents"] == 0

      group = get_group(conn, "group-retained")
      assert group["status"] == "cancelled"
      assert group["credit_paid_cents"] == 0

      # consuming the credit reduced the liability permanently
      assert ledger(conn)["credit_liability_cents"] == 7_000
      assert ledger(conn)["cash_retained_cents"] == 1_000
      assert guest_credit(conn, "guest-22")["available_cents"] == 7_000
    end
  end

  describe "credit reads" do
    test "omits expired lots and honours the on parameter", %{conn: conn} do
      issue_credit(conn, "op-cancel-a", "group-a", 1_000, "2026-05-01")
      issue_credit(conn, "op-cancel-b", "group-b", 1_000, "2026-11-26")

      assert guest_credit(conn, "guest-22")["available_cents"] == 2_200
      assert ledger(conn)["credit_liability_cents"] == 2_200

      # as of a date after the first lot's expiry, only the second remains
      credits = guest_credit(conn, "guest-22", on: "2027-06-01")

      assert credits["available_cents"] == 1_100

      assert Enum.map(credits["lots"], & &1["source_operation_id"]) == ["op-cancel-b"]
      assert ledger(conn, on: "2027-06-01")["credit_liability_cents"] == 1_100

      # once both have expired nothing remains
      assert guest_credit(conn, "guest-22", on: "2028-01-01") == %{
               "guest_id" => "guest-22",
               "available_cents" => 0,
               "lots" => []
             }

      assert ledger(conn, on: "2028-01-01")["credit_liability_cents"] == 0
    end

    test "exhausted lots disappear from reads", %{conn: conn} do
      issue_credit(conn, "op-cancel-a", "group-a", 1_000, "2026-05-01")
      apply_open!(conn, "group-81")

      submit(conn, [credit_op("op-use", "group-81", 1_000)])
      submit(conn, [credit_op("op-more", "group-81", 100)])

      assert guest_credit(conn, "guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 0,
               "lots" => []
             }
    end

    test "a guest without credit has empty reads", %{conn: conn} do
      assert guest_credit(conn, "guest-nobody") == %{
               "guest_id" => "guest-nobody",
               "available_cents" => 0,
               "lots" => []
             }
    end
  end

  # Helpers

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp only_result(response) do
    [result] = response["results"]
    result
  end

  defp rejection(response, code) do
    result = only_result(response)

    result["status"] == "rejected" and result["code"] == code
  end

  defp apply_open!(conn, group_id, opts \\ []) do
    result =
      submit(conn, [
        open_op(group_id, opts)
      ])
      |> only_result()

    assert result["status"] == "applied"
    result
  end

  defp open_op(group_id, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-open-" <> group_id),
      "type" => "open_group",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => Keyword.get(opts, :arrival_on, "2026-12-10"),
      "departure_on" => Keyword.get(opts, :departure_on, "2026-12-13"),
      "rate_plan" => Keyword.get(opts, :rate_plan, "flexible"),
      "rooms" =>
        Keyword.get(
          opts,
          :rooms,
          [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
          ]
        )
    }
  end

  defp payment_op(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => @booked_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp reschedule_op(operation_id, group_id, new_arrival_on) do
    %{
      "operation_id" => operation_id,
      "type" => "reschedule_group",
      "occurred_on" => @booked_on,
      "group_id" => group_id,
      "new_arrival_on" => new_arrival_on
    }
  end

  defp cancel_op(operation_id, group_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  defp credit_cancel_op(operation_id, group_id, occurred_on) do
    cancel_op(operation_id, group_id, occurred_on)
    |> Map.put("refund_method", "hotel_credit")
  end

  defp credit_op(operation_id, group_id, amount_cents, opts \\ []) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  # Cancels a freshly paid flexible group with hotel credit so guest-22 ends
  # up with a credit lot of round(cash * 110%) expiring 366 days later.
  defp issue_credit(conn, operation_id, group_id, cash_cents, occurred_on) do
    apply_open!(conn, group_id)

    if cash_cents > 0 do
      submit(conn, [payment_op("op-pay-" <> group_id, group_id, cash_cents)])
    end

    result = only_result(submit(conn, [credit_cancel_op(operation_id, group_id, occurred_on)]))
    assert result["status"] == "applied"
    result
  end

  defp open_and_get(conn, group_id, opts) do
    apply_open!(conn, group_id, opts)
    get_group(conn, group_id)
  end

  defp get_conn(conn, group_id), do: get(conn, "/api/v1/groups/#{group_id}")

  defp get_group(conn, group_id) do
    conn |> get_conn(group_id) |> json_response(200) |> Map.fetch!("data")
  end

  defp ledger(conn, opts \\ []) do
    conn |> get(on_path("/api/v1/ledger", opts)) |> json_response(200) |> Map.fetch!("data")
  end

  defp guest_credit(conn, guest_id, opts \\ []) do
    conn
    |> get(on_path("/api/v1/guests/#{guest_id}/credit", opts))
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp on_path(path, opts) do
    case Keyword.fetch(opts, :on) do
      {:ok, on} -> path <> "?on=" <> on
      :error -> path
    end
  end
end
