defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerTestHelpers

  @docs_example %{
    "operation_id" => "op-1001",
    "type" => "open_group",
    "occurred_on" => "2026-10-03",
    "group_id" => "group-81",
    "guest_id" => "guest-22",
    "property_id" => "ams-canal",
    "arrival_on" => "2026-12-10",
    "departure_on" => "2026-12-13",
    "rate_plan" => "flexible",
    "rooms" => [
      %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
      %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
    ]
  }

  describe "POST /api/v1/partner-batches" do
    test "applies the documented example and reports its result" do
      conn = submit(build_conn(), [@docs_example])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19500,
                   "revision" => 1
                 }
               ]
             }
    end

    test "returns one result per operation in order" do
      conn =
        submit(build_conn(), [
          open_group_operation(),
          payment_operation(),
          reschedule_operation()
        ])

      results = json_response(conn, 200)["results"]
      assert Enum.map(results, & &1["operation_id"]) == ["op-open", "op-pay", "op-move"]
      assert Enum.map(results, & &1["status"]) == ["applied", "applied", "applied"]
    end

    test "an empty batch returns an empty result list" do
      conn = submit(build_conn(), [])

      assert json_response(conn, 200) == %{"results" => []}
    end

    test "a body without an operations array is an invalid batch" do
      conn = post(build_conn(), "/api/v1/partner-batches", %{})

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "an operations value that is not an array is an invalid batch" do
      conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => "nope"})

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "a rejected operation does not undo earlier operations or stop later ones" do
      conn =
        submit(build_conn(), [
          open_group_operation(),
          open_group_operation(%{"operation_id" => "op-open-2"}),
          payment_operation()
        ])

      [open, duplicate, payment] = json_response(conn, 200)["results"]

      assert open["status"] == "applied"
      assert duplicate["code"] == "group_already_exists"
      assert payment["status"] == "applied"
      assert payment["outstanding_deposit_cents"] == 9000 - 5000

      conn = get(build_conn(), "/api/v1/groups/group-1")
      assert json_response(conn, 200)["data"]["deposit_paid_cents"] == 5000
    end
  end

  describe "open_group" do
    test "requires a stay of at least one night" do
      cases = [
        {%{"departure_on" => "2026-12-10"}, "same-day departure"},
        {%{"departure_on" => "2026-12-09"}, "departure before arrival"},
        {%{"arrival_on" => "not-a-date"}, "unparseable arrival"},
        {%{"arrival_on" => nil}, "missing arrival"},
        {%{"departure_on" => nil}, "missing departure"}
      ]

      for {{attrs, label}, index} <- Enum.with_index(cases) do
        conn =
          submit(build_conn(), [
            open_group_operation(Map.put(attrs, "operation_id", "op-stay-#{index}"))
          ])

        assert [result] = json_response(conn, 200)["results"]
        assert result["code"] == "invalid_stay", "expected invalid_stay for #{label}"
      end
    end

    test "requires at least one room with unique identifiers and usable rates" do
      cases = [
        {%{"rooms" => []}, "no rooms"},
        {%{"rooms" => nil}, "missing rooms"},
        {%{"rooms" => "room-a"}, "rooms not a list"},
        {%{
           "rooms" => [
             %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
             %{"room_id" => "room-a", "nightly_rate_cents" => 16000}
           ]
         }, "duplicate room ids"},
        {%{"rooms" => [%{"nightly_rate_cents" => 15000}]}, "room without id"},
        {%{"rooms" => [%{"room_id" => "room-a"}]}, "room without rate"},
        {%{"rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 0}]}, "zero rate"},
        {%{"rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => -100}]}, "negative rate"},
        {%{"rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 150.5}]},
         "fractional rate"},
        {%{"rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => "15000"}]}, "string rate"}
      ]

      for {{attrs, label}, index} <- Enum.with_index(cases) do
        conn =
          submit(build_conn(), [
            open_group_operation(Map.put(attrs, "operation_id", "op-rooms-#{index}"))
          ])

        assert [result] = json_response(conn, 200)["results"]
        assert result["code"] == "invalid_rooms", "expected invalid_rooms for #{label}"
      end
    end

    test "requires a known rate plan" do
      conn = submit(build_conn(), [open_group_operation(%{"rate_plan" => "corporate"})])
      assert [%{"code" => "invalid_rate_plan"}] = json_response(conn, 200)["results"]

      conn =
        submit(build_conn(), [
          open_group_operation(%{"rate_plan" => nil, "operation_id" => "op-plan-2"})
        ])

      assert [%{"code" => "invalid_rate_plan"}] = json_response(conn, 200)["results"]
    end

    test "rejects duplicate group identifiers without changing the existing group" do
      apply_operations!(build_conn(), [open_group_operation()])

      conn =
        submit(build_conn(), [
          open_group_operation(%{
            "operation_id" => "op-open-2",
            "rooms" => [%{"room_id" => "room-z", "nightly_rate_cents" => 99999}]
          })
        ])

      assert [%{"code" => "group_already_exists", "operation_id" => "op-open-2"}] =
               json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      assert json_response(conn, 200)["data"]["lodging_total_cents"] == 3 * 15000
    end

    test "flexible deposits round each room separately to the nearest cent" do
      conn =
        submit(build_conn(), [
          open_group_operation(%{
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "r1", "nightly_rate_cents" => 1234},
              %{"room_id" => "r2", "nightly_rate_cents" => 1234},
              %{"room_id" => "r3", "nightly_rate_cents" => 1234}
            ]
          })
        ])

      assert [%{"deposit_due_cents" => 741, "status" => "applied"}] =
               json_response(conn, 200)["results"]
    end

    test "advance purchase deposits equal the full lodging total" do
      conn =
        submit(build_conn(), [
          open_group_operation(%{
            "rate_plan" => "advance_purchase",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 10000},
              %{"room_id" => "room-b", "nightly_rate_cents" => 10000}
            ]
          })
        ])

      assert [%{"deposit_due_cents" => 60000, "status" => "applied"}] =
               json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      assert json_response(conn, 200)["data"]["lodging_total_cents"] == 60000
    end

    test "rejects operations missing identifying data with invalid_operation" do
      cases = [
        {%{"operation_id" => nil}, "missing operation_id"},
        {%{"group_id" => nil}, "missing group_id"},
        {%{"guest_id" => nil}, "missing guest_id"},
        {%{"property_id" => nil}, "missing property_id"},
        {%{"occurred_on" => nil}, "missing occurred_on"},
        {%{"occurred_on" => "2026-13-01"}, "unparseable occurred_on"}
      ]

      for {{attrs, label}, index} <- Enum.with_index(cases) do
        conn =
          submit(build_conn(), [
            open_group_operation(Map.put(attrs, "operation_id", op_id(attrs, "op-data", index)))
          ])

        assert [result] = json_response(conn, 200)["results"]
        assert result["code"] == "invalid_operation", "expected invalid_operation for #{label}"
      end
    end

    test "rejects unknown types and malformed operations with invalid_operation" do
      for {operation, index} <-
            Enum.with_index([
              %{
                "operation_id" => "op-x",
                "type" => "rename_group",
                "group_id" => "group-1",
                "occurred_on" => "2026-10-03"
              },
              %{"operation_id" => "op-x", "group_id" => "group-1", "occurred_on" => "2026-10-03"},
              %{
                "operation_id" => "op-x",
                "type" => "record_cash_payment",
                "occurred_on" => "2026-10-03"
              },
              "not-an-operation",
              42
            ]) do
        conn = submit(build_conn(), [with_unique_operation_id(operation, index)])

        assert [result] = json_response(conn, 200)["results"]
        assert result["code"] == "invalid_operation"
      end
    end
  end

  describe "record_cash_payment" do
    test "applies cash to the outstanding deposit" do
      apply_operations!(build_conn(), [open_group_operation()])

      conn =
        submit(build_conn(), [payment_operation(%{"amount_cents" => 3000})])

      assert [%{"status" => "applied"} = result] = json_response(conn, 200)["results"]

      assert result ==
               %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "group-1",
                 "amount_cents" => 3000,
                 "outstanding_deposit_cents" => 6000,
                 "revision" => 2
               }
    end

    test "rejects a payment for a missing group" do
      conn = submit(build_conn(), [payment_operation(%{"group_id" => "nope"})])

      assert [%{"code" => "group_not_found"}] = json_response(conn, 200)["results"]
    end

    test "rejects unusable amounts" do
      apply_operations!(build_conn(), [open_group_operation()])

      for {amount, index} <- Enum.with_index([0, -100, "5000", 500.5, nil]) do
        conn =
          submit(build_conn(), [
            payment_operation(%{
              "amount_cents" => amount,
              "operation_id" => "op-amount-#{index}"
            })
          ])

        assert [%{"code" => "invalid_amount"}] = json_response(conn, 200)["results"]
      end
    end

    test "rejects payments exceeding the outstanding deposit" do
      apply_operations!(build_conn(), [open_group_operation()])

      conn =
        submit(build_conn(), [payment_operation(%{"amount_cents" => 9001})])

      assert [%{"code" => "payment_exceeds_outstanding"}] = json_response(conn, 200)["results"]

      conn =
        submit(build_conn(), [
          payment_operation(%{"amount_cents" => 9000, "operation_id" => "op-pay-exact"})
        ])

      assert [%{"status" => "applied", "outstanding_deposit_cents" => 0}] =
               json_response(conn, 200)["results"]

      conn =
        submit(build_conn(), [
          payment_operation(%{"amount_cents" => 1, "operation_id" => "op-pay-1"})
        ])

      assert [%{"code" => "payment_exceeds_outstanding"}] = json_response(conn, 200)["results"]
    end

    test "rejects a payment to a group that is no longer active" do
      apply_operations!(build_conn(), [open_group_operation(), cancel_operation()])

      conn = submit(build_conn(), [payment_operation(%{"operation_id" => "op-pay-2"})])
      assert [%{"code" => "group_not_active"}] = json_response(conn, 200)["results"]
    end
  end

  describe "reschedule_group" do
    test "shifts arrival and departure by the same number of days" do
      apply_operations!(build_conn(), [open_group_operation()])

      conn = submit(build_conn(), [reschedule_operation()])

      assert [%{"status" => "applied"} = result] = json_response(conn, 200)["results"]

      assert result ==
               %{
                 "operation_id" => "op-move",
                 "status" => "applied",
                 "group_id" => "group-1",
                 "new_arrival_on" => "2026-12-15",
                 "new_departure_on" => "2026-12-18",
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-12-01",
                 "revision" => 2
               }

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]
      assert data["arrival_on"] == "2026-12-15"
      assert data["departure_on"] == "2026-12-18"
      assert data["lodging_total_cents"] == 3 * 15000
    end

    test "increments the revision even when the dates do not change" do
      apply_operations!(build_conn(), [open_group_operation()])

      conn =
        submit(build_conn(), [
          reschedule_operation(%{"occurred_on" => "2026-10-05", "new_arrival_on" => "2026-12-10"})
        ])

      assert [%{"status" => "applied", "revision" => 2, "new_arrival_on" => "2026-12-10"}] =
               json_response(conn, 200)["results"]
    end

    test "rejects unusable arrival dates" do
      apply_operations!(build_conn(), [open_group_operation()])

      cases = [
        {%{"new_arrival_on" => nil}, "missing arrival"},
        {%{"new_arrival_on" => "2026-13-40"}, "unparseable arrival"},
        {%{"new_arrival_on" => "2026-10-05"}, "arrival on the operation date"},
        {%{"new_arrival_on" => "2026-10-01"}, "arrival before the operation date"}
      ]

      for {{attrs, label}, index} <- Enum.with_index(cases) do
        conn =
          submit(build_conn(), [
            reschedule_operation(Map.put(attrs, "operation_id", "op-arrival-#{index}"))
          ])

        assert [result] = json_response(conn, 200)["results"]
        assert result["code"] == "invalid_stay", "expected invalid_stay for #{label}"
      end
    end

    test "rejects reschedules for missing or inactive groups" do
      conn = submit(build_conn(), [reschedule_operation(%{"group_id" => "nope"})])
      assert [%{"code" => "group_not_found"}] = json_response(conn, 200)["results"]

      apply_operations!(build_conn(), [open_group_operation(), cancel_operation()])

      conn = submit(build_conn(), [reschedule_operation(%{"operation_id" => "op-move-2"})])
      assert [%{"code" => "group_not_active"}] = json_response(conn, 200)["results"]
    end
  end

  describe "cancel_group" do
    test "refunds flexible groups cancelled at least fourteen days before arrival" do
      apply_operations!(build_conn(), [
        open_group_operation(),
        payment_operation(%{"amount_cents" => 4000})
      ])

      conn =
        submit(build_conn(), [
          cancel_operation(%{"occurred_on" => "2026-11-26", "operation_id" => "op-cancel"})
        ])

      assert [%{"status" => "applied"} = result] = json_response(conn, 200)["results"]

      assert result ==
               %{
                 "operation_id" => "op-cancel",
                 "status" => "applied",
                 "group_id" => "group-1",
                 "refunded_cents" => 4000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
    end

    test "retains cash for flexible groups cancelled within fourteen days of arrival" do
      apply_operations!(build_conn(), [
        open_group_operation(),
        payment_operation(%{"amount_cents" => 4000})
      ])

      conn =
        submit(build_conn(), [
          cancel_operation(%{"occurred_on" => "2026-11-27"})
        ])

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 4000}] =
               json_response(conn, 200)["results"]
    end

    test "always retains cash for advance purchase groups" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"rate_plan" => "advance_purchase"}),
        payment_operation(%{"amount_cents" => 4000})
      ])

      conn =
        submit(build_conn(), [
          cancel_operation(%{"occurred_on" => "2026-10-04"})
        ])

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 4000}] =
               json_response(conn, 200)["results"]
    end

    test "an unpaid group cancels with no cash movement and no outstanding deposit" do
      apply_operations!(build_conn(), [open_group_operation()])

      conn = submit(build_conn(), [cancel_operation()])

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 0}] =
               json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]
      assert data["status"] == "cancelled"
      assert data["outstanding_deposit_cents"] == 0
    end

    test "rejects a second cancellation" do
      apply_operations!(build_conn(), [open_group_operation(), cancel_operation()])

      conn = submit(build_conn(), [cancel_operation(%{"operation_id" => "op-cancel-2"})])
      assert [%{"code" => "group_not_active"}] = json_response(conn, 200)["results"]
    end

    test "rejects cancellation of a missing group" do
      conn = submit(build_conn(), [cancel_operation(%{"group_id" => "nope"})])
      assert [%{"code" => "group_not_found"}] = json_response(conn, 200)["results"]
    end
  end

  describe "policy versions" do
    test "flexible groups booked before 2027 keep the fourteen-day window" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"occurred_on" => "2026-12-31"})
      ])

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]

      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2026-11-26"
    end

    test "flexible groups booked on or after 2027 use the thirty-day window" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-04"
        })
      ])

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]

      assert data["policy_version"] == "flex-30"
      assert data["refundable_until"] == "2027-01-30"

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 4000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0
               }
             ] =
               apply_operations!(build_conn(), [
                 payment_operation(%{"amount_cents" => 4000}),
                 cancel_operation(%{
                   "occurred_on" => "2027-01-30",
                   "operation_id" => "op-cancel-1"
                 })
               ])
               |> Enum.drop(1)

      conn = get(build_conn(), "/api/v1/ledger")
      assert json_response(conn, 200)["data"]["cash_refunded_cents"] == 4000
    end

    test "cancellation one day inside the thirty-day window is non-refundable" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-04"
        }),
        payment_operation(%{"amount_cents" => 4000}),
        cancel_operation(%{"occurred_on" => "2027-01-31"})
      ])

      conn = get(build_conn(), "/api/v1/ledger")
      assert json_response(conn, 200)["data"]["cash_retained_cents"] == 4000
    end

    test "advance purchase groups are non-refundable with no refundable_until" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"rate_plan" => "advance_purchase"})
      ])

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]

      assert data["policy_version"] == "advance-nonrefundable"
      assert data["refundable_until"] == nil
    end

    test "rescheduling a group never moves it to a newer policy" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "occurred_on" => "2026-12-31",
          "arrival_on" => "2027-02-01",
          "departure_on" => "2027-02-04"
        }),
        reschedule_operation(%{
          "occurred_on" => "2027-01-02",
          "new_arrival_on" => "2027-02-10"
        }),
        payment_operation(%{"occurred_on" => "2027-01-02", "amount_cents" => 3000})
      ])

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]
      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2027-01-27"

      # Sixteen days before arrival: refundable under flex-14, not under flex-30.
      assert [
               %{"refunded_cents" => 3000, "retained_cents" => 0, "credit_issued_cents" => 0}
             ] =
               apply_operations!(build_conn(), [
                 cancel_operation(%{"occurred_on" => "2027-01-25"})
               ])
    end
  end

  describe "cancel_group refund_method" do
    test "hotel credit converts refundable cash into a lot worth 110%" do
      apply_operations!(build_conn(), [
        open_group_operation(),
        payment_operation(%{"amount_cents" => 9000})
      ])

      assert [
               %{
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 9900,
                 "revision" => 3
               }
             ] =
               apply_operations!(build_conn(), [
                 cancel_operation(%{"refund_method" => "hotel_credit"})
               ])

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")

      assert json_response(conn, 200)["data"] == %{
               "guest_id" => "guest-22",
               "available_cents" => 9900,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel",
                   "remaining_cents" => 9900,
                   "expires_on" => "2027-11-26"
                 }
               ]
             }

      conn = get(build_conn(), "/api/v1/ledger")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 9000,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_shortfall_cents" => 0,
               "credit_liability_cents" => 9900
             }
    end

    test "the ten percent bonus rounds half a cent upward" do
      apply_operations!(build_conn(), [
        open_group_operation(),
        payment_operation(%{"amount_cents" => 1235}),
        cancel_operation(%{"refund_method" => "hotel_credit"})
      ])

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")

      assert [%{"remaining_cents" => 1359}] = json_response(conn, 200)["data"]["lots"]
    end

    test "an explicit cash refund method preserves the cash settlement" do
      apply_operations!(build_conn(), [
        open_group_operation(),
        payment_operation(%{"amount_cents" => 4000}),
        cancel_operation(%{"refund_method" => "cash"})
      ])

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")
      assert json_response(conn, 200)["data"]["available_cents"] == 0

      conn = get(build_conn(), "/api/v1/ledger")
      data = json_response(conn, 200)["data"]
      assert data["cash_refunded_cents"] == 4000
      assert data["cash_converted_to_credit_cents"] == 0
      assert data["credit_liability_cents"] == 0
    end

    test "hotel credit is rejected for non-refundable advance purchase groups" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"rate_plan" => "advance_purchase"}),
        payment_operation(%{"amount_cents" => 4000})
      ])

      conn =
        submit(build_conn(), [
          cancel_operation(%{"refund_method" => "hotel_credit"})
        ])

      assert [%{"code" => "refund_method_not_available"}] = json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]
      assert data["status"] == "active"
      assert data["revision"] == 2

      conn = get(build_conn(), "/api/v1/ledger")
      assert json_response(conn, 200)["data"]["cash_held_cents"] == 4000
    end

    test "hotel credit is rejected for a flexible group cancelled too late" do
      apply_operations!(build_conn(), [
        open_group_operation(),
        payment_operation(%{"amount_cents" => 4000})
      ])

      conn =
        submit(build_conn(), [
          cancel_operation(%{"occurred_on" => "2026-11-27", "refund_method" => "hotel_credit"})
        ])

      assert [%{"code" => "refund_method_not_available"}] = json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      assert json_response(conn, 200)["data"]["status"] == "active"
    end

    test "an unusable refund method is rejected" do
      apply_operations!(build_conn(), [open_group_operation()])

      conn = submit(build_conn(), [cancel_operation(%{"refund_method" => "voucher"})])

      assert [%{"code" => "invalid_operation"}] = json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      assert json_response(conn, 200)["data"]["status"] == "active"
    end

    test "a rejected refund method does not advance the revision" do
      apply_operations!(build_conn(), [
        open_group_operation(),
        payment_operation(%{"amount_cents" => 4000})
      ])

      conn =
        submit(build_conn(), [
          cancel_operation(%{
            "operation_id" => "op-credit-cancel",
            "refund_method" => "hotel_credit",
            "occurred_on" => "2026-11-27"
          })
        ])

      assert [%{"code" => "refund_method_not_available"}] = json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      assert json_response(conn, 200)["data"]["revision"] == 2
    end

    test "hotel credit can still be chosen after a reschedule" do
      apply_operations!(build_conn(), [
        open_group_operation(),
        payment_operation(%{"amount_cents" => 4000}),
        reschedule_operation(),
        cancel_operation(%{"refund_method" => "hotel_credit"})
      ])

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")

      assert [%{"remaining_cents" => 4400, "expires_on" => "2027-11-26"}] =
               json_response(conn, 200)["data"]["lots"]
    end
  end

  describe "revisions" do
    test "each applied operation increments the revision exactly once" do
      results =
        apply_operations!(build_conn(), [
          open_group_operation(),
          payment_operation(%{"amount_cents" => 1000}),
          reschedule_operation(),
          cancel_operation()
        ])

      assert Enum.map(results, & &1["revision"]) == [1, 2, 3, 4]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      assert json_response(conn, 200)["data"]["revision"] == 4
    end

    test "rejections never increment the revision" do
      apply_operations!(build_conn(), [open_group_operation()])

      conn =
        submit(build_conn(), [
          payment_operation(%{"operation_id" => "op-bad", "amount_cents" => 0}),
          payment_operation(%{"operation_id" => "op-missing", "group_id" => "nope"}),
          open_group_operation(%{"operation_id" => "op-dup"})
        ])

      assert Enum.map(json_response(conn, 200)["results"], & &1["status"]) ==
               ["rejected", "rejected", "rejected"]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      assert json_response(conn, 200)["data"]["revision"] == 1
    end

    test "rejects a stale expected_revision before other domain rules and leaves the group unchanged" do
      apply_operations!(build_conn(), [
        open_group_operation(),
        payment_operation(%{"amount_cents" => 1000})
      ])

      conn =
        submit(build_conn(), [
          payment_operation(%{
            "operation_id" => "op-stale",
            "amount_cents" => 0,
            "expected_revision" => 1
          })
        ])

      assert [
               %{
                 "operation_id" => "op-stale",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-1",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]
      assert data["revision"] == 2
      assert data["deposit_paid_cents"] == 1000
    end

    test "a stale revision is rejected before the inactive check" do
      apply_operations!(build_conn(), [open_group_operation(), cancel_operation()])

      conn =
        submit(build_conn(), [
          cancel_operation(%{"operation_id" => "op-cancel-2", "expected_revision" => 1})
        ])

      assert [%{"code" => "stale_revision", "expected_revision" => 1, "actual_revision" => 2}] =
               json_response(conn, 200)["results"]
    end

    test "a matching expected_revision is applied" do
      apply_operations!(build_conn(), [open_group_operation()])

      conn =
        submit(build_conn(), [
          payment_operation(%{"amount_cents" => 1000, "expected_revision" => 1})
        ])

      assert [%{"status" => "applied", "revision" => 2}] = json_response(conn, 200)["results"]
    end

    test "expected_revision observes changes made earlier in the same batch" do
      conn =
        submit(build_conn(), [
          open_group_operation(),
          payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 1000}),
          payment_operation(%{
            "operation_id" => "op-pay-2",
            "amount_cents" => 1000,
            "expected_revision" => 2
          }),
          payment_operation(%{
            "operation_id" => "op-pay-3",
            "amount_cents" => 1000,
            "expected_revision" => 2
          })
        ])

      assert Enum.map(json_response(conn, 200)["results"], & &1["status"]) ==
               ["applied", "applied", "applied", "rejected"]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      assert json_response(conn, 200)["data"]["revision"] == 3
      assert json_response(conn, 200)["data"]["deposit_paid_cents"] == 2000
    end

    test "open_group does not use expected_revision" do
      conn =
        submit(build_conn(), [
          open_group_operation(%{"expected_revision" => 99})
        ])

      assert [%{"status" => "applied", "revision" => 1}] = json_response(conn, 200)["results"]
    end
  end

  defp op_id(attrs, prefix, index) do
    case attrs do
      %{"operation_id" => nil} -> nil
      _other -> "#{prefix}-#{index}"
    end
  end

  defp with_unique_operation_id(operation, index) when is_map(operation),
    do: Map.put(operation, "operation_id", "op-type-#{index}")

  defp with_unique_operation_id(operation, _index), do: operation
end
