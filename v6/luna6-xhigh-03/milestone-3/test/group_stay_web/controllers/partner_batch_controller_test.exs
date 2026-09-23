defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: "open-1",
        type: "open_group",
        occurred_on: "2026-10-03",
        group_id: "group-81",
        guest_id: "guest-22",
        property_id: "ams-canal",
        arrival_on: "2026-12-10",
        departure_on: "2026-12-13",
        rate_plan: "flexible",
        rooms: [
          %{room_id: "room-a", nightly_rate_cents: 101},
          %{room_id: "room-b", nightly_rate_cents: 103}
        ]
      },
      overrides
    )
  end

  test "opens groups, processes operations in order, and settles refundable cash", %{conn: conn} do
    response =
      post_batch(conn, [
        open_operation(),
        %{
          operation_id: "pay-1",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "group-81",
          amount_cents: 123,
          expected_revision: 1
        },
        %{
          operation_id: "move-1",
          type: "reschedule_group",
          occurred_on: "2026-10-05",
          group_id: "group-81",
          new_arrival_on: "2026-12-20",
          expected_revision: 2
        },
        %{
          operation_id: "cancel-1",
          type: "cancel_group",
          occurred_on: "2026-12-06",
          group_id: "group-81",
          expected_revision: 3
        }
      ])
      |> json_response(200)

    assert [
             %{"status" => "applied", "deposit_due_cents" => 123, "revision" => 1},
             %{"status" => "applied", "outstanding_deposit_cents" => 0, "revision" => 2},
             %{
               "status" => "applied",
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23",
               "revision" => 3
             },
             %{
               "status" => "applied",
               "refunded_cents" => 123,
               "retained_cents" => 0,
               "revision" => 4
             }
           ] = response["results"]

    group =
      conn
      |> get("/api/v1/groups/group-81")
      |> json_response(200)
      |> Map.fetch!("data")

    assert group["status"] == "cancelled"
    assert group["revision"] == 4
    assert group["lodging_total_cents"] == 612
    assert group["deposit_paid_cents"] == 123
    assert group["cash_paid_cents"] == 123
    assert group["credit_paid_cents"] == 0
    assert group["outstanding_deposit_cents"] == 0
    assert Enum.map(group["rooms"], & &1["room_id"]) == ["room-a", "room-b"]

    ledger =
      conn
      |> get("/api/v1/ledger")
      |> json_response(200)
      |> Map.fetch!("data")

    assert ledger == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 123,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "rejections do not change the group and stale revisions precede domain validation", %{
    conn: conn
  } do
    response =
      post_batch(conn, [
        open_operation(),
        %{
          operation_id: "too-much",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "group-81",
          amount_cents: 124,
          expected_revision: 1
        },
        %{
          operation_id: "valid-pay",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "group-81",
          amount_cents: 100,
          expected_revision: 1
        },
        %{
          operation_id: "stale-invalid-pay",
          type: "record_cash_payment",
          occurred_on: "not-a-date",
          group_id: "group-81",
          amount_cents: -10,
          expected_revision: 1
        }
      ])
      |> json_response(200)

    assert Enum.map(response["results"], & &1["status"]) == [
             "applied",
             "rejected",
             "applied",
             "rejected"
           ]

    assert response["results"] |> Enum.at(1) |> Map.fetch!("code") ==
             "payment_exceeds_outstanding"

    assert response["results"] |> Enum.at(3) == %{
             "operation_id" => "stale-invalid-pay",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    group =
      conn
      |> get("/api/v1/groups/group-81")
      |> json_response(200)
      |> Map.fetch!("data")

    assert group["revision"] == 2
    assert group["deposit_paid_cents"] == 100

    assert conn
           |> get("/api/v1/ledger")
           |> json_response(200)
           |> get_in(["data", "cash_held_cents"]) == 100
  end

  test "advance purchase cancellation retains cash and later mutations are rejected", %{
    conn: conn
  } do
    response =
      post_batch(conn, [
        open_operation(%{
          group_id: "advance-group",
          rate_plan: "advance_purchase",
          rooms: [%{room_id: "room-a", nightly_rate_cents: 1000}]
        }),
        %{
          operation_id: "pay-advance",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "advance-group",
          amount_cents: 3000
        },
        %{
          operation_id: "cancel-advance",
          type: "cancel_group",
          occurred_on: "2026-10-04",
          group_id: "advance-group"
        },
        %{
          operation_id: "pay-cancelled",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "advance-group",
          amount_cents: 1
        }
      ])
      |> json_response(200)

    assert Enum.at(response["results"], 0)["deposit_due_cents"] == 3000
    assert Enum.at(response["results"], 2)["retained_cents"] == 3000
    assert Enum.at(response["results"], 3)["code"] == "group_not_active"

    ledger =
      conn
      |> get("/api/v1/ledger")
      |> json_response(200)
      |> Map.fetch!("data")

    assert ledger == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 3000,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "late flexible cancellation retains paid cash and releases unpaid deposit", %{conn: conn} do
    response =
      post_batch(conn, [
        open_operation(%{group_id: "late-flexible-group"}),
        %{
          operation_id: "pay-late",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "late-flexible-group",
          amount_cents: 50
        },
        %{
          operation_id: "cancel-late",
          type: "cancel_group",
          occurred_on: "2026-12-09",
          group_id: "late-flexible-group"
        }
      ])
      |> json_response(200)

    assert Enum.at(response["results"], 2)["refunded_cents"] == 0
    assert Enum.at(response["results"], 2)["retained_cents"] == 50

    group =
      conn
      |> get("/api/v1/groups/late-flexible-group")
      |> json_response(200)
      |> Map.fetch!("data")

    assert group["deposit_paid_cents"] == 50
    assert group["outstanding_deposit_cents"] == 0
  end

  test "uses the documented opening validation codes", %{conn: conn} do
    results =
      post_batch(conn, [
        open_operation(%{
          operation_id: "bad-stay-open",
          group_id: "bad-stay",
          arrival_on: "2026-12-13"
        }),
        open_operation(%{
          operation_id: "bad-rooms-open",
          group_id: "bad-rooms",
          rooms: [
            %{room_id: "duplicate", nightly_rate_cents: 100},
            %{room_id: "duplicate", nightly_rate_cents: 200}
          ]
        }),
        open_operation(%{
          operation_id: "bad-plan-open",
          group_id: "bad-plan",
          rate_plan: "nonrefundable"
        })
      ])
      |> json_response(200)
      |> Map.fetch!("results")

    assert Enum.map(results, & &1["code"]) == [
             "invalid_stay",
             "invalid_rooms",
             "invalid_rate_plan"
           ]
  end

  test "rejects an invalid batch and reports missing groups", %{conn: conn} do
    assert conn
           |> put_req_header("content-type", "application/json")
           |> post("/api/v1/partner-batches", Jason.encode!(%{operations: "not-an-array"}))
           |> json_response(422) == %{"error" => %{"code" => "invalid_batch"}}

    assert conn
           |> get("/api/v1/groups/missing-group")
           |> json_response(404) == %{"error" => %{"code" => "group_not_found"}}

    assert conn
           |> get("/api/v1/guests/guest-22/credit?on=invalid")
           |> json_response(422) == %{"error" => %{"code" => "invalid_date"}}

    assert conn
           |> get("/api/v1/ledger?on=invalid")
           |> json_response(422) == %{"error" => %{"code" => "invalid_date"}}
  end

  test "fixes cancellation policy at booking and recomputes the window after a move", %{
    conn: conn
  } do
    results =
      post_batch(conn, [
        open_operation(%{
          operation_id: "open-flex-14-policy",
          group_id: "flex-14-group",
          occurred_on: "2026-12-31"
        }),
        open_operation(%{
          operation_id: "open-flex-30-policy",
          group_id: "flex-30-group",
          occurred_on: "2027-01-01",
          arrival_on: "2027-03-10",
          departure_on: "2027-03-12"
        }),
        %{
          open_operation(%{
            group_id: "advance-policy-group",
            occurred_on: "2027-01-01",
            rate_plan: "advance_purchase"
          })
          | operation_id: "open-advance-policy"
        },
        %{
          operation_id: "move-flex-30",
          type: "reschedule_group",
          occurred_on: "2027-01-02",
          group_id: "flex-30-group",
          new_arrival_on: "2027-04-01",
          expected_revision: 1
        }
      ])
      |> json_response(200)
      |> Map.fetch!("results")

    assert Enum.at(results, 3) == %{
             "operation_id" => "move-flex-30",
             "status" => "applied",
             "group_id" => "flex-30-group",
             "new_arrival_on" => "2027-04-01",
             "new_departure_on" => "2027-04-03",
             "policy_version" => "flex-30",
             "refundable_until" => "2027-03-02",
             "revision" => 2
           }

    groups =
      ["flex-14-group", "flex-30-group", "advance-policy-group"]
      |> Enum.map(fn group_id ->
        conn
        |> get("/api/v1/groups/#{group_id}")
        |> json_response(200)
        |> get_in(["data", "policy_version"])
      end)

    assert groups == ["flex-14", "flex-30", "advance-nonrefundable"]

    assert conn
           |> get("/api/v1/groups/advance-policy-group")
           |> json_response(200)
           |> get_in(["data", "refundable_until"]) == nil
  end

  test "converts refundable cash into rounded hotel credit", %{conn: conn} do
    results =
      post_batch(conn, [
        open_operation(%{group_id: "credit-conversion-group"}),
        %{
          operation_id: "credit-conversion-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "credit-conversion-group",
          amount_cents: 15
        },
        %{
          operation_id: "credit-conversion-cancel",
          type: "cancel_group",
          occurred_on: "2026-11-26",
          group_id: "credit-conversion-group",
          refund_method: "hotel_credit"
        }
      ])
      |> json_response(200)
      |> Map.fetch!("results")

    assert Enum.at(results, 2) == %{
             "operation_id" => "credit-conversion-cancel",
             "status" => "applied",
             "group_id" => "credit-conversion-group",
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 17,
             "revision" => 3
           }

    group =
      conn
      |> get("/api/v1/groups/credit-conversion-group")
      |> json_response(200)
      |> Map.fetch!("data")

    assert group["policy_version"] == "flex-14"
    assert group["refundable_until"] == "2026-11-26"
    assert group["cash_paid_cents"] == 15
    assert group["credit_paid_cents"] == 0

    credit =
      conn
      |> get("/api/v1/guests/guest-22/credit?on=2027-11-26")
      |> json_response(200)
      |> Map.fetch!("data")

    assert credit == %{
             "guest_id" => "guest-22",
             "available_cents" => 17,
             "lots" => [
               %{
                 "source_operation_id" => "credit-conversion-cancel",
                 "remaining_cents" => 17,
                 "expires_on" => "2027-11-26"
               }
             ]
           }

    ledger =
      conn
      |> get("/api/v1/ledger?on=2027-11-26")
      |> json_response(200)
      |> Map.fetch!("data")

    assert ledger["cash_held_cents"] == 0
    assert ledger["cash_converted_to_credit_cents"] == 15
    assert ledger["credit_liability_cents"] == 17
  end

  test "applies credit by expiry and source order, then restores only unexpired allocations", %{
    conn: conn
  } do
    source_operations = [
      open_operation(%{
        operation_id: "open-credit-source-a",
        group_id: "credit-source-a",
        occurred_on: "2025-12-01",
        arrival_on: "2026-02-01",
        departure_on: "2026-02-02",
        rooms: [%{room_id: "room-a", nightly_rate_cents: 100}]
      }),
      %{
        operation_id: "pay-credit-source-a",
        type: "record_cash_payment",
        occurred_on: "2025-12-02",
        group_id: "credit-source-a",
        amount_cents: 10
      },
      %{
        operation_id: "cancel-a",
        type: "cancel_group",
        occurred_on: "2026-01-01",
        group_id: "credit-source-a",
        refund_method: "hotel_credit"
      },
      open_operation(%{
        operation_id: "open-credit-source-b",
        group_id: "credit-source-b",
        occurred_on: "2025-12-01",
        arrival_on: "2026-02-01",
        departure_on: "2026-02-02",
        rooms: [%{room_id: "room-a", nightly_rate_cents: 100}]
      }),
      %{
        operation_id: "pay-credit-source-b",
        type: "record_cash_payment",
        occurred_on: "2025-12-02",
        group_id: "credit-source-b",
        amount_cents: 10
      },
      %{
        operation_id: "cancel-b",
        type: "cancel_group",
        occurred_on: "2026-01-02",
        group_id: "credit-source-b",
        refund_method: "hotel_credit"
      },
      open_operation(%{
        operation_id: "open-credit-source-c",
        group_id: "credit-source-c",
        occurred_on: "2025-12-01",
        arrival_on: "2026-02-01",
        departure_on: "2026-02-02",
        rooms: [%{room_id: "room-a", nightly_rate_cents: 100}]
      }),
      %{
        operation_id: "pay-credit-source-c",
        type: "record_cash_payment",
        occurred_on: "2025-12-02",
        group_id: "credit-source-c",
        amount_cents: 10
      },
      %{
        operation_id: "cancel-c",
        type: "cancel_group",
        occurred_on: "2026-01-02",
        group_id: "credit-source-c",
        refund_method: "hotel_credit"
      }
    ]

    assert conn
           |> post_batch(source_operations)
           |> json_response(200)
           |> Map.fetch!("results")
           |> Enum.at(2)
           |> Map.fetch!("credit_issued_cents") == 11

    target_operations = [
      open_operation(%{
        group_id: "credit-target",
        arrival_on: "2027-02-01",
        departure_on: "2027-02-02",
        rooms: [%{room_id: "room-a", nightly_rate_cents: 1000}]
      }),
      %{
        operation_id: "credit-too-much-available",
        type: "apply_hotel_credit",
        occurred_on: "2026-12-31",
        group_id: "credit-target",
        amount_cents: 34,
        expected_revision: 1
      },
      %{
        operation_id: "apply-credit",
        type: "apply_hotel_credit",
        occurred_on: "2026-12-31",
        group_id: "credit-target",
        amount_cents: 15,
        expected_revision: 1
      }
    ]

    target_results =
      conn
      |> post_batch(target_operations)
      |> json_response(200)
      |> Map.fetch!("results")

    assert Enum.at(target_results, 1)["code"] == "insufficient_credit"

    assert Enum.at(target_results, 2) == %{
             "operation_id" => "apply-credit",
             "status" => "applied",
             "group_id" => "credit-target",
             "amount_cents" => 15,
             "outstanding_deposit_cents" => 185,
             "revision" => 2
           }

    in_use_ledger =
      conn
      |> get("/api/v1/ledger?on=2026-12-31")
      |> json_response(200)
      |> get_in(["data", "credit_liability_cents"])

    assert in_use_ledger == 33

    assert conn
           |> get("/api/v1/guests/guest-22/credit?on=2026-12-31")
           |> json_response(200)
           |> get_in(["data", "lots"]) == [
             %{
               "source_operation_id" => "cancel-b",
               "remaining_cents" => 7,
               "expires_on" => "2027-01-02"
             },
             %{
               "source_operation_id" => "cancel-c",
               "remaining_cents" => 11,
               "expires_on" => "2027-01-02"
             }
           ]

    assert conn
           |> post_batch([
             %{
               operation_id: "cancel-credit-target",
               type: "cancel_group",
               occurred_on: "2027-01-02",
               group_id: "credit-target",
               expected_revision: 2
             }
           ])
           |> json_response(200)
           |> get_in(["results", Access.at(0), "credit_issued_cents"]) == 0

    target =
      conn
      |> get("/api/v1/groups/credit-target")
      |> json_response(200)
      |> Map.fetch!("data")

    assert target["deposit_paid_cents"] == 15
    assert target["cash_paid_cents"] == 0
    assert target["credit_paid_cents"] == 15

    assert conn
           |> get("/api/v1/guests/guest-22/credit?on=2027-01-02")
           |> json_response(200)
           |> get_in(["data", "lots"]) == [
             %{
               "source_operation_id" => "cancel-b",
               "remaining_cents" => 11,
               "expires_on" => "2027-01-02"
             },
             %{
               "source_operation_id" => "cancel-c",
               "remaining_cents" => 11,
               "expires_on" => "2027-01-02"
             }
           ]

    assert conn
           |> get("/api/v1/ledger?on=2027-01-02")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 22

    assert conn
           |> get("/api/v1/ledger?on=2027-01-03")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 0

    assert conn
           |> get("/api/v1/guests/guest-22/credit?on=2027-01-03")
           |> json_response(200)
           |> get_in(["data", "lots"]) == []
  end

  test "hotel credit is rejected for nonrefundable cancellations after revision checking", %{
    conn: conn
  } do
    results =
      post_batch(conn, [
        open_operation(%{
          group_id: "nonrefundable-credit-group",
          rate_plan: "advance_purchase"
        }),
        %{
          operation_id: "pay-nonrefundable-credit-group",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "nonrefundable-credit-group",
          amount_cents: 100
        },
        %{
          operation_id: "stale-credit-refund",
          type: "cancel_group",
          occurred_on: "2026-10-05",
          group_id: "nonrefundable-credit-group",
          refund_method: "hotel_credit",
          expected_revision: 1
        },
        %{
          operation_id: "unavailable-credit-refund",
          type: "cancel_group",
          occurred_on: "2026-10-05",
          group_id: "nonrefundable-credit-group",
          refund_method: "hotel_credit",
          expected_revision: 2
        }
      ])
      |> json_response(200)
      |> Map.fetch!("results")

    assert Enum.at(results, 2)["code"] == "stale_revision"
    assert Enum.at(results, 3)["code"] == "refund_method_not_available"

    group =
      conn
      |> get("/api/v1/groups/nonrefundable-credit-group")
      |> json_response(200)
      |> Map.fetch!("data")

    assert group["status"] == "active"
    assert group["revision"] == 2
  end
end
